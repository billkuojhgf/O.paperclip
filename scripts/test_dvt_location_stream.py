"""Worker behavior tests; fake services never enter the production CLI."""
import asyncio
import unittest
from contextlib import asynccontextmanager
import json
import io
import os
from types import SimpleNamespace
from unittest.mock import patch

from pymobiledevice3 import exceptions

import dvt_location_stream as worker


class Service:
    def __init__(self):
        self.calls = []
        self.release = asyncio.Event()

    async def set(self, latitude, longitude):
        await self.release.wait()
        self.calls.append((latitude, longitude))

    async def clear(self):
        self.calls.append("clear")


class CommandTests(unittest.IsolatedAsyncioTestCase):
    async def test_set_ack_follows_completed_service_effect(self):
        service = Service()
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"id":1,"op":"set","latitude":25.033,"longitude":121.5654}\n')
        reader.feed_data(b'{"id":2,"op":"quit"}\n')
        reader.feed_eof()
        events = []
        task = asyncio.create_task(worker.command_loop(reader, service, events.append))
        await asyncio.sleep(0)
        self.assertEqual(events, [])
        service.release.set()
        await task
        self.assertEqual(service.calls, [(25.033, 121.5654), "clear"])
        self.assertEqual(events, [{"event": "ack", "id": 1}, {"event": "ack", "id": 2}])

    async def test_invalid_data_has_no_set_effect_and_reader_keeps_progressing(self):
        service = Service()
        service.release.set()
        reader = asyncio.StreamReader(limit=worker.MAX_LINE)
        events = []
        task = asyncio.create_task(worker.command_loop(reader, service, events.append))
        await asyncio.sleep(0)
        self.assertFalse(task.done())
        bad = [
            {"id": 1, "op": "set", "latitude": float("nan"), "longitude": 0},
            {"id": 2, "op": "set", "latitude": float("inf"), "longitude": 0},
            {"id": 3, "op": "set", "latitude": 91, "longitude": 0},
            {"id": 4, "op": "set", "latitude": 0, "longitude": -181},
            {"id": 5, "op": "set", "latitude": True, "longitude": 0},
            {"id": 6, "op": "set", "latitude": 0, "longitude": 0, "extra": 1},
            {"id": True, "op": "clear"},
            {"id": 7, "op": "unknown"},
        ]
        for request in bad:
            reader.feed_data(json.dumps(request).encode() + b"\n")
        reader.feed_data(b"x" * (worker.MAX_LINE + 1) + b"\n")
        reader.feed_data(b'{"id":8,"op":"set","latitude":-90,"longitude":180}\n')
        reader.feed_eof()
        await task
        self.assertEqual(service.calls, [(-90, 180)])
        self.assertEqual([event["event"] for event in events], ["error"] * 9 + ["ack"])
        self.assertEqual(events[-1]["id"], 8)

    async def test_stop_is_logical_and_clear_remains_usable(self):
        service = Service()
        service.release.set()
        reader = asyncio.StreamReader()
        for request_id, op in enumerate(("start-stream", "stop-stream", "set", "clear", "quit"), 1):
            request = {"id": request_id, "op": op}
            if op == "set":
                request.update(latitude=25, longitude=121)
            reader.feed_data(json.dumps(request).encode() + b"\n")
        reader.feed_eof()
        events, state = [], {}
        await worker.command_loop(reader, service, events.append, state=state)
        self.assertFalse(state["streaming"])
        self.assertEqual(service.calls, [(25, 121), "clear", "clear"])
        self.assertTrue(all(event["event"] == "ack" for event in events))

    async def test_clear_error_does_not_become_ack_or_close_connection(self):
        service = Service()
        async def fail_clear():
            raise OSError("fixture clear failure")
        service.clear = fail_clear
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"id":1,"op":"clear"}\n{"id":2,"op":"stop-stream"}\n')
        reader.feed_eof()
        events = []
        await worker.command_loop(reader, service, events.append)
        self.assertEqual(events[0]["event"], "error")
        self.assertFalse(events[0]["fatal"])
        self.assertEqual(events[1], {"event": "ack", "id": 2})

    async def test_duplicate_id_and_fragmented_json_cannot_apply_twice(self):
        reader = asyncio.StreamReader()
        service = Service()
        service.release.set()
        events = []
        task = asyncio.create_task(worker.command_loop(reader, service, events.append))
        reader.feed_data(b'{"id":1,"op":"set","latitude":25,')
        await asyncio.sleep(0)
        self.assertEqual(service.calls, [])
        reader.feed_data(b'"longitude":121}\n{"id":1,"op":"set","latitude":26,"longitude":122}\n')
        reader.feed_eof()
        await task
        self.assertEqual(service.calls, [(25, 121)])
        self.assertEqual(events[1]["code"], "invalid_request")

    async def test_timeout_is_fatal_and_never_acknowledged(self):
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"id":1,"op":"set","latitude":25,"longitude":121}\n')
        events, state = [], {}
        with patch.object(worker, "COMMAND_TIMEOUT", 0.01):
            await worker.command_loop(reader, Service(), events.append, state=state)
        self.assertEqual(events[0]["code"], "timeout")
        self.assertTrue(events[0]["fatal"])
        self.assertTrue(state["fatal"])


class ProviderTests(unittest.IsolatedAsyncioTestCase):
    def runtime(self, *, cdp_error=None, usb_version="17.4", network_error=None, pair_record=True):
        calls = []
        class Resource:
            udid = "phone-A"
            product_version = usb_version
            all_values = {"DeviceName": "Phone A"}
            async def close(self):
                calls.append("lockdown-close")
        async def usbmux(**kwargs):
            calls.append(("usbmux", kwargs))
            if network_error is not None and kwargs["connection_type"] == "Network":
                raise network_error
            return Resource()
        class CDP:
            @classmethod
            async def create(cls, lockdown):
                calls.append("cdp")
                if cdp_error is not None:
                    raise cdp_error
                return cls()
            async def close(self):
                calls.append("proxy-close")
        class Native:
            def __init__(self, serial):
                calls.append(("native", serial))
            async def __aenter__(self):
                return Resource()
            async def __aexit__(self, *args):
                calls.append("native-close")
        runtime = {
            "exceptions": exceptions,
            "create_using_usbmux": usbmux,
            "NativeRemotedTunnel": Native,
            "tunnel_service": SimpleNamespace(USE_USERSPACE_TUNNEL=False, CoreDeviceTunnelProxy=CDP),
            "iter_remote_pair_records_by_identifier": lambda: iter([
                ("phone-A", None, {"peer_alt_irk": b"key"})] if pair_record else []),
        }
        return runtime, calls, Resource

    async def test_only_usb_capability_absence_selects_native(self):
        error = exceptions.InvalidServiceError("missing CDP", "phone-A", "17.4")
        runtime, calls, _ = self.runtime(cdp_error=error)
        async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime) as device:
            self.assertEqual(device.transport, "native")
        self.assertLess(calls.index("lockdown-close"), calls.index(("native", "phone-A")))
        self.assertIn("native-close", calls)
        self.assertFalse(runtime["tunnel_service"].USE_USERSPACE_TUNNEL)
        runtime, calls, _ = self.runtime(cdp_error=OSError("network failure"))
        with self.assertRaises(OSError):
            async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime):
                self.fail("network failure must not yield a provider")
        self.assertFalse(any(isinstance(call, tuple) and call[0] == "native" for call in calls))
        self.assertEqual(calls[-1], "lockdown-close")

    async def test_legacy_keeps_explicit_network_route(self):
        runtime, calls, _ = self.runtime(usb_version="16.7")
        async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime) as device:
            self.assertEqual(device.transport, "lockdown-wifi")
        self.assertEqual(calls[0], ("usbmux", {"serial": "phone-A", "connection_type": "Network", "autopair": False}))
        self.assertNotIn("cdp", calls)

    async def test_wifi_missing_pair_record_and_wrong_identity_fail_closed(self):
        runtime, calls, _ = self.runtime(network_error=exceptions.DeviceNotFoundError("no Network device"), pair_record=False)
        with self.assertRaises(worker.WorkerError) as caught:
            async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime):
                self.fail("missing pairing must not connect")
        self.assertEqual(caught.exception.code, "pairing_required")
        runtime, calls, resource = self.runtime(usb_version="16.7")
        resource.udid = "phone-B"
        with self.assertRaises(worker.WorkerError) as caught:
            async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime):
                self.fail("wrong device must not connect")
        self.assertEqual(caught.exception.code, "identity_mismatch")
        self.assertEqual(calls[-1], "lockdown-close")

    async def test_wifi_network_pairing_error_never_browses_or_switches_device(self):
        runtime, calls, _ = self.runtime(network_error=exceptions.UserDeniedPairingError())
        with self.assertRaises(exceptions.UserDeniedPairingError):
            async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime):
                self.fail("denied pairing must fail")
        self.assertEqual(len(calls), 1)

    async def test_teardown_failure_still_closes_every_owner_and_resets_flag(self):
        runtime, calls, resource = self.runtime()
        async def open_userspace(runtime, stack, provider, protocol):
            async def fail_close():
                calls.append("rsd-close")
                raise OSError("close failure")
            async def dial_close():
                calls.append("dial-close")
            async def tunnel_close():
                calls.append("tunnel-close")
            stack.push_async_callback(tunnel_close)
            stack.push_async_callback(dial_close)
            stack.push_async_callback(fail_close)
            return resource(), None
        with patch.object(worker, "open_userspace", open_userspace):
            with self.assertRaises(OSError):
                async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime):
                    pass
        self.assertEqual(calls[-5:], ["rsd-close", "dial-close", "tunnel-close", "proxy-close", "lockdown-close"])
        self.assertFalse(runtime["tunnel_service"].USE_USERSPACE_TUNNEL)

    async def test_wifi_protocol_retry_reacquires_same_udid_after_cleanup(self):
        runtime, calls, resource = self.runtime(network_error=exceptions.DeviceNotFoundError("no Network device"))
        class Provider:
            remote_identifier = "phone-A"
            async def close(self):
                calls.append("wifi-close")
        async def discover(udid):
            calls.append(("discover", udid))
            return [Provider()]
        runtime["tunnel_service"].get_remote_pairing_tunnel_services = discover
        async def open_userspace(runtime, stack, provider, protocol):
            calls.append(protocol)
            if protocol == "tcp":
                raise worker.TunnelAttemptError() from OSError("TCP blocked")
            return resource(), None
        with patch.object(worker, "open_userspace", open_userspace):
            async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime) as device:
                self.assertEqual(device.transport, "userspace-wifi")
        self.assertEqual(calls[1:5], [("discover", "phone-A"), "tcp", "wifi-close", ("discover", "phone-A")])

    async def test_manual_endpoint_uses_handshake_and_closes_on_mismatch(self):
        runtime, calls, resource = self.runtime()
        class RSD(resource):
            def __init__(self, address, handshake_uuid):
                calls.append((address, handshake_uuid))
            async def connect(self):
                pass
        runtime.update(RemoteServiceDiscoveryService=RSD, rsd_handshake_uuid=lambda host: None)
        async with worker.open_device_provider("phone-A", "usb", ("::1", 1234), runtime=runtime) as device:
            self.assertEqual(device.transport, "manual-rsd")
        self.assertEqual(calls, [(("::1", 1234), None), "lockdown-close"])

    async def test_cancelled_setup_releases_owned_provider(self):
        runtime, calls, _ = self.runtime()
        entered = asyncio.Event()
        async def open_userspace(*args):
            entered.set()
            await asyncio.Event().wait()
        async def connect():
            async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime):
                self.fail("cancelled setup must not connect")
        with patch.object(worker, "open_userspace", open_userspace):
            task = asyncio.create_task(connect())
            await entered.wait()
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(calls[-2:], ["proxy-close", "lockdown-close"])
        self.assertFalse(runtime["tunnel_service"].USE_USERSPACE_TUNNEL)

    async def test_usb_bootstrap_reopens_only_after_pair_completion_without_deletion(self):
        runtime, calls, resource = self.runtime(pair_record=False)
        records = []
        runtime["iter_remote_pair_records_by_identifier"] = lambda: iter(records)
        class Pairing:
            @classmethod
            async def create(cls, lockdown):
                calls.append(("pair-create", lockdown.udid))
                return cls()
            async def connect(self, autopair):
                calls.append(("pair-connect", autopair))
                if not records:
                    records.append(("phone-A", None, {"peer_alt_irk": b"key"}))
                    raise exceptions.RemotePairingCompletedError()
            async def close(self):
                calls.append("pair-close")
        runtime["tunnel_service"].RemotePairingLockdownService = Pairing
        await worker.bootstrap_usb_pairing(runtime, resource())
        self.assertEqual(calls, [("pair-create", "phone-A"), ("pair-connect", True), "pair-close"] * 2)
        await worker.bootstrap_usb_pairing(runtime, resource())
        self.assertEqual(len(calls), 6)

    async def test_valid_old_pairing_without_altirk_is_refreshed_for_wifi(self):
        runtime, calls, resource = self.runtime(pair_record=False)
        records = [("phone-A", None, {"private_key": b"existing"})]
        runtime["iter_remote_pair_records_by_identifier"] = lambda: iter(records)
        class Pairing:
            @classmethod
            async def create(cls, lockdown):
                return cls()
            async def connect(self, autopair):
                calls.append("old-record-verified")
            async def _pair(self):
                records[0] = ("phone-A", None, {"peer_alt_irk": b"new-key"})
            async def close(self):
                calls.append("pair-close")
        runtime["tunnel_service"].RemotePairingLockdownService = Pairing
        await worker.bootstrap_usb_pairing(runtime, resource())
        self.assertTrue(worker.has_wifi_pair_record(runtime, "phone-A"))
        self.assertEqual(calls, ["old-record-verified", "pair-close"])

    async def test_stale_wifi_metadata_does_not_block_valid_usb(self):
        runtime, calls, resource = self.runtime(pair_record=False)
        class Pairing:
            @classmethod
            async def create(cls, lockdown):
                return cls()
            async def connect(self, autopair):
                calls.append("pair-verified")
            async def _pair(self):
                calls.append("pair-no-wifi-metadata")
            async def close(self):
                calls.append("pair-close")
        runtime["tunnel_service"].RemotePairingLockdownService = Pairing
        async def connected(runtime, stack, proxy, protocol):
            return resource(), None
        with patch.object(worker, "open_userspace", connected):
            async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime) as device:
                self.assertEqual(device.transport, "userspace-usb")
        self.assertIn("pair-verified", calls)

    async def test_usb_pairing_rejection_is_not_hidden(self):
        runtime, calls, _ = self.runtime(pair_record=False)
        class Pairing:
            @classmethod
            async def create(cls, lockdown):
                return cls()
            async def connect(self, autopair):
                raise exceptions.NotTrustedError()
            async def close(self):
                calls.append("pair-close")
        runtime["tunnel_service"].RemotePairingLockdownService = Pairing
        with self.assertRaises(exceptions.NotTrustedError):
            async with worker.open_device_provider("phone-A", "usb", None, runtime=runtime):
                self.fail("trust rejection must not connect")
        self.assertEqual(calls[-3:], ["pair-close", "proxy-close", "lockdown-close"])

    async def test_wifi_discovery_cannot_select_other_identity(self):
        runtime, calls, _ = self.runtime(network_error=exceptions.DeviceNotFoundError("not on network"))
        class Other:
            remote_identifier = "phone-B"
            async def close(self):
                calls.append("other-close")
        async def discover(udid):
            calls.append(("discover", udid))
            return [Other()]
        runtime["tunnel_service"].get_remote_pairing_tunnel_services = discover
        with self.assertRaises(worker.WorkerError) as caught:
            async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime):
                self.fail("another device must not satisfy this request")
        self.assertEqual(caught.exception.code, "wifi_unavailable")
        self.assertEqual(calls[-2:], [("discover", "phone-A"), "other-close"])

    async def test_userspace_reuses_tun_and_closes_rsd_before_dial_and_tunnel(self):
        calls = []
        class Tun:
            def set_peer(self, address):
                calls.append(("peer", address))
        tun = Tun()
        class Tunnel:
            @asynccontextmanager
            async def start_tcp_tunnel(self):
                try:
                    yield SimpleNamespace(client=SimpleNamespace(tun=tun, wait_closed=lambda: None),
                                          address="fd00::1", port=1234, auxiliary_metadata={"test": {}})
                finally:
                    calls.append("tunnel-close")
        class Dial:
            def __init__(self, given_tun, address):
                self.asserted_tun = given_tun
                self.address = address
            async def __aenter__(self):
                calls.append(("dial", self.asserted_tun is tun, self.address))
                return self
            async def __aexit__(self, *args):
                calls.append("dial-close")
            async def dial(self, *args):
                pass
        class RSD:
            def __init__(self, address, open_connection, auxiliary_metadata):
                calls.append(("rsd", address, auxiliary_metadata))
            async def connect(self):
                calls.append("rsd-connect")
            async def close(self):
                calls.append("rsd-close")
        runtime = {"exceptions": exceptions, "UserspaceTun": Tun, "UserspaceDialPlane": Dial,
                   "RemoteServiceDiscoveryService": RSD}
        async with worker.AsyncExitStack() as stack:
            await worker.open_userspace(runtime, stack, Tunnel(), "tcp")
        self.assertEqual(calls[:2], [("peer", "fd00::1"), ("dial", True, "fd00::1")])
        self.assertEqual(calls[-3:], ["rsd-close", "dial-close", "tunnel-close"])

    async def test_wifi_rsd_failure_never_retries_tunnel_protocol(self):
        runtime, calls, _ = self.runtime(network_error=exceptions.DeviceNotFoundError("not on network"))
        class Provider:
            remote_identifier = "phone-A"
            async def close(self):
                calls.append("wifi-close")
        async def discover(udid):
            calls.append(("discover", udid))
            return [Provider()]
        async def rsd_failure(runtime, stack, provider, protocol):
            calls.append(protocol)
            raise OSError("RSD failed after tunnel established")
        runtime["tunnel_service"].get_remote_pairing_tunnel_services = discover
        with patch.object(worker, "open_userspace", rsd_failure):
            with self.assertRaises(OSError):
                async with worker.open_device_provider("phone-A", "wifi", None, runtime=runtime):
                    self.fail("RSD failure must fail the session")
        self.assertEqual(calls[-3:], [("discover", "phone-A"), "tcp", "wifi-close"])



class SessionTests(unittest.IsolatedAsyncioTestCase):
    def runtime(self, *, mount_error=None, dvt_error=None):
        calls = []
        disconnected = asyncio.Event()
        class Provider:
            udid = "phone-A"
            product_version = "17.4"
            all_values = {"DeviceName": "Phone A"}
        @asynccontextmanager
        async def owner(*args, **kwargs):
            try:
                yield worker.DeviceProvider(Provider(), "userspace-usb")
            finally:
                calls.append("provider-close")
        class Mounter:
            def __init__(self, lockdown):
                pass
            async def query_developer_mode_status(self):
                calls.append("developer-mode")
                return True
            async def close(self):
                calls.append("mounter-close")
        async def mount(provider):
            calls.append("mount")
            if mount_error:
                raise mount_error
        class DVT:
            def __init__(self, provider):
                self.dtx = SimpleNamespace(wait_disconnected=disconnected.wait)
            async def connect(self):
                calls.append("dvt-connect")
                if dvt_error:
                    raise dvt_error
            async def close(self):
                calls.append("dvt-close")
        class Location:
            def __init__(self, provider):
                calls.append("location-instance")
            async def connect(self):
                calls.append("channel-connect")
            async def clear(self):
                calls.append("clear")
            async def set(self, latitude, longitude):
                calls.append((latitude, longitude))
        return owner, {"exceptions": exceptions, "MobileImageMounterService": Mounter,
                       "auto_mount": mount, "DvtProvider": DVT, "LocationSimulation": Location,
                       "DtSimulateLocation": Location}, calls, disconnected

    async def test_stop_start_reuses_channel_and_ready_follows_mount_and_clear(self):
        owner, runtime, calls, _ = self.runtime()
        reader = asyncio.StreamReader()
        for request_id, op in enumerate(("start-stream", "stop-stream", "start-stream", "set", "quit"), 1):
            request = {"id": request_id, "op": op}
            if op == "set":
                request.update(latitude=25.033, longitude=121.5654)
            reader.feed_data(json.dumps(request).encode() + b"\n")
        events = []
        def emit(event):
            if event["event"] == "ready":
                self.assertIn("mount", calls)
                self.assertEqual(calls[-1], "clear")
            events.append(event)
        with patch.object(worker, "open_device_provider", owner):
            result = await worker.run_session(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), reader, emit, runtime=runtime)
        self.assertEqual(result, 0)
        self.assertEqual(calls.count("location-instance"), 1)
        self.assertEqual(calls.count("channel-connect"), 1)
        self.assertEqual(calls.count("clear"), 2)
        self.assertEqual(calls[-2:], ["dvt-close", "provider-close"])
        self.assertIn((25.033, 121.5654), calls)

    async def test_mount_failure_cannot_emit_ready(self):
        owner, runtime, calls, _ = self.runtime(mount_error=OSError("DDI unavailable"))
        events = []
        with patch.object(worker, "open_device_provider", owner):
            result = await worker.run_session(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), asyncio.StreamReader(), events.append, runtime=runtime)
        self.assertEqual(result, 1)
        self.assertNotIn("ready", [event["event"] for event in events])
        self.assertNotIn("dvt-connect", calls)
        self.assertEqual(calls[-1], "provider-close")

    async def test_already_mounted_ddi_still_prepares_location(self):
        owner, runtime, calls, _ = self.runtime(mount_error=exceptions.AlreadyMountedError())
        reader = asyncio.StreamReader()
        reader.feed_data(b'{"id":1,"op":"set","latitude":25.033,"longitude":121.5654}\n{"id":2,"op":"quit"}\n')
        events = []
        with patch.object(worker, "open_device_provider", owner):
            result = await worker.run_session(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), reader, events.append, runtime=runtime)
        self.assertEqual(result, 0)
        self.assertIn("ready", [event["event"] for event in events])
        self.assertIn((25.033, 121.5654), calls)

    async def test_dvt_timeout_is_not_legacy_success(self):
        owner, runtime, calls, _ = self.runtime(dvt_error=TimeoutError())
        events = []
        with patch.object(worker, "open_device_provider", owner):
            result = await worker.run_session(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), asyncio.StreamReader(), events.append, runtime=runtime)
        self.assertEqual(result, 1)
        self.assertEqual(events[-1]["code"], "timeout")
        self.assertNotIn("location-instance", calls)
        self.assertEqual(calls[-2:], ["dvt-close", "provider-close"])

    async def test_dvt_disconnect_fails_idle_worker_without_stdin_input(self):
        owner, runtime, calls, disconnected = self.runtime()
        ready = asyncio.Event()
        events = []
        def emit(event):
            events.append(event)
            if event["event"] == "ready":
                ready.set()
        with patch.object(worker, "open_device_provider", owner):
            task = asyncio.create_task(worker.run_session(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), asyncio.StreamReader(), emit, runtime=runtime))
            await ready.wait()
            disconnected.set()
            self.assertEqual(await task, 1)
        self.assertEqual(events[-1]["code"], "transport_lost")
        self.assertEqual(calls[-2:], ["dvt-close", "provider-close"])

    async def test_stdin_eof_cancels_delayed_setup_and_releases_provider(self):
        owner, runtime, calls, _ = self.runtime()
        entered = asyncio.Event()
        async def delayed_query(mounter):
            entered.set()
            await asyncio.Event().wait()
        runtime["MobileImageMounterService"].query_developer_mode_status = delayed_query
        read_fd, write_fd = os.pipe()
        with io.TextIOWrapper(os.fdopen(read_fd, "rb")) as stdin:
            with patch.object(worker.sys, "stdin", stdin), patch.object(worker, "load_runtime", lambda: runtime), patch.object(worker, "open_device_provider", owner):
                task = asyncio.create_task(worker.run_worker(SimpleNamespace(udid="phone-A", connection_type="usb", rsd=None), lambda event: None))
                try:
                    await entered.wait()
                    os.close(write_fd)
                    write_fd = None
                    self.assertEqual(await asyncio.wait_for(task, 1), 0)
                finally:
                    if write_fd is not None:
                        os.close(write_fd)
                    await worker.cancel_tasks([task])
        self.assertEqual(calls[-2:], ["mounter-close", "provider-close"])


class ArgumentTests(unittest.TestCase):
    def test_partial_endpoint_and_empty_automatic_identity_are_rejected(self):
        for argv in (["--rsd", "localhost"], ["--rsd", "", "1234"],
                     ["--rsd", "localhost", "65536"], ["--udid", " "],
                     ["--rsd", "localhost", "1234", "--connection-type", "usb"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                worker.parse_arguments(argv)

    def test_root_refusal_happens_before_runtime_or_connection(self):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(worker.os, "geteuid", lambda: 0), patch.object(worker.sys, "stdout", output), patch.object(worker.sys, "stderr", errors), patch.object(worker, "load_runtime") as runtime:
            self.assertEqual(worker.main(["--udid", "phone-A"]), 1)
        runtime.assert_not_called()
        self.assertEqual(output.getvalue(), "")
        self.assertIn("不可由 root 執行", errors.getvalue())

    def test_runtime_check_prints_only_diagnostic_json_without_connecting(self):
        output = io.StringIO()
        with patch.object(worker.sys, "stdout", output), patch.object(worker, "load_runtime", return_value={}) as runtime, patch.object(worker, "run_worker") as run:
            self.assertEqual(worker.main(["--check-runtime"]), 0)
        runtime.assert_called_once_with()
        run.assert_not_called()
        self.assertEqual(json.loads(output.getvalue()), {"pymobiledevice3": "11.49.2", "userspace": True, "dvt": True})

    def test_duplicate_fields_and_non_utf8_input_are_invalid(self):
        for raw in (b'{"id":1,"op":"clear","op":"set"}\n',
                    '{"id":1,"op":"clear"}\n'.encode("utf-16")):
            with self.subTest(raw=raw), self.assertRaises(worker.WorkerError) as caught:
                worker.parse_request(raw, 0)
            self.assertEqual(caught.exception.code, "invalid_request")


if __name__ == "__main__":
    unittest.main()
