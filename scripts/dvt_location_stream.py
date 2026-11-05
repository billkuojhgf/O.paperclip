#!/usr/bin/env python3
"""One non-root device owner. stdin/stdout carry protocol v1 NDJSON only."""
import argparse
import asyncio
from contextlib import AsyncExitStack, asynccontextmanager, redirect_stdout
from dataclasses import dataclass
from importlib.metadata import version
import json
import logging
import math
import os
from pathlib import Path
import signal
import ssl
import sys

VERSION = "11.49.2"
MAX_LINE = 64 * 1024
TUNNEL_TIMEOUT = 60
MOUNT_TIMEOUT = 45
VALIDATION_TIMEOUT = 25
COMMAND_TIMEOUT = 15
LOG = logging.getLogger(__name__)
PAIRING_GUIDANCE = "Wi‑Fi 遠端配對資料尚未就緒，請切換 USB 連線以建立本 App 的配對；既有信任與配對檔未刪除。"


class WorkerError(Exception):
    def __init__(self, code, message, request_id=None, fatal=False):
        super().__init__(message)
        self.code = code
        self.request_id = request_id
        self.fatal = fatal

    def event(self):
        return {"event": "error", "id": self.request_id, "code": self.code,
                "message": str(self), "fatal": self.fatal}


def load_runtime():
    """Load the same modules used by the bundled worker without opening a device."""
    os.umask(0o077)
    from pymobiledevice3 import common
    # Worker 私有程序統一使用 App 配對目錄，避免讀寫舊版 root-only 記錄。
    common._HOMEFOLDER = Path.home() / "Library/Application Support/fregata.O-PaperclipPackaging/Pairing"
    common._HOMEFOLDER.mkdir(parents=True, exist_ok=True, mode=0o700)
    from pymobiledevice3 import exceptions
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.pair_records import iter_remote_pair_records_by_identifier
    from pymobiledevice3.remote import tunnel_service
    from pymobiledevice3.remote.native_tunnel import NativeRemotedTunnel
    from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
    from pymobiledevice3.remote.remotexpc import rsd_handshake_uuid
    from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
    from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService, auto_mount
    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    from pymobiledevice3.services.simulate_location import DtSimulateLocation
    if version("pymobiledevice3") != VERSION:
        raise RuntimeError("pymobiledevice3 版本必須為 " + VERSION)
    if not ssl.OPENSSL_VERSION.startswith("OpenSSL") or not getattr(ssl, "HAS_PSK", False):
        raise RuntimeError("Python 必須使用支援 PSK 的 OpenSSL")
    return locals()


def error_from_exception(exc, request_id=None, fatal=False):
    if isinstance(exc, WorkerError):
        return WorkerError(exc.code, str(exc), request_id, fatal or exc.fatal)
    # Use typed exceptions / structured lockdown error codes, never message matching.
    try:
        from pymobiledevice3 import exceptions as e
    except ImportError:
        return WorkerError("operation_failed", "定位執行環境不完整，請重新安裝應用程式。", request_id, fatal)
    if isinstance(exc, (e.PasswordRequiredError, e.PasscodeRequiredError)) or (
        isinstance(exc, e.LockdownError) and exc.error == "DeviceLocked"
    ):
        code, message = "device_locked", "裝置已鎖定，請解鎖 iPhone 並保持螢幕開啟後重試。"
    elif isinstance(exc, (e.PairingError, e.NotPairedError, e.NotTrustedError, e.FatalPairingError)):
        code, message = "pairing_required", PAIRING_GUIDANCE
    elif isinstance(exc, e.DeveloperModeIsNotEnabledError):
        code, message = "developer_mode_disabled", "請在 iPhone「設定 → 隱私權與安全性」開啟開發者模式，重新啟動並確認後重試。"
    elif isinstance(exc, TimeoutError):
        code, message = "timeout", "裝置操作逾時，請確認裝置連線後重試。"
    elif isinstance(exc, (e.DeviceNotFoundError, e.ConnectionTerminatedError, OSError)):
        code, message = "transport_unavailable", "無法建立裝置通道，請確認連線、信任與配對狀態。"
    else:
        code, message = "operation_failed", "裝置操作失敗，請確認裝置狀態後重試。"
    return WorkerError(code, message, request_id, fatal)


def verify_identity(provider, udid):
    if not provider.udid or (udid is not None and provider.udid != udid):
        raise WorkerError("identity_mismatch", "連線裝置身分與指定裝置不符。")


def has_wifi_pair_record(runtime, udid):
    return any(identifier == udid and bool(record.get("peer_alt_irk"))
               for identifier, _, record in runtime["iter_remote_pair_records_by_identifier"]())


async def bootstrap_usb_pairing(runtime, lockdown):
    if has_wifi_pair_record(runtime, lockdown.udid):
        return
    service_class = runtime["tunnel_service"].RemotePairingLockdownService
    # Pairing closes its own socket. Reopen only after that explicit completion signal.
    for attempt in range(2):
        async with AsyncExitStack() as stack:
            service = await service_class.create(lockdown)
            stack.push_async_callback(service.close)
            try:
                await service.connect(autopair=True)
                if not has_wifi_pair_record(runtime, lockdown.udid):
                    await service._pair()
            except runtime["exceptions"].RemotePairingCompletedError:
                if attempt == 0:
                    continue
                raise
            break
    if not has_wifi_pair_record(runtime, lockdown.udid):
        LOG.warning(PAIRING_GUIDANCE)


@dataclass
class DeviceProvider:
    provider: object
    transport: str
    wait_closed: object = None


class TunnelAttemptError(Exception):
    """Only establishment failures may select the other Wi-Fi tunnel protocol."""


async def open_userspace(runtime, stack, provider, protocol):
    e = runtime["exceptions"]
    tunnel_context = (provider.start_tcp_tunnel() if protocol == "tcp"
                      else provider.start_quic_tunnel())
    try:
        result = await stack.enter_async_context(tunnel_context)
    except (OSError, EOFError, asyncio.IncompleteReadError, e.ConnectionTerminatedError,
            e.UnsupportedCommandError, e.MessageNotSupportedError,
            e.QuicProtocolNotSupportedError, e.ProtocolError) as exc:
        raise TunnelAttemptError() from exc
    tun = result.client.tun
    if not isinstance(tun, runtime["UserspaceTun"]):
        raise RuntimeError("未建立 userspace tunnel")
    tun.set_peer(result.address)
    dial_plane = await stack.enter_async_context(runtime["UserspaceDialPlane"](tun, result.address))
    rsd = runtime["RemoteServiceDiscoveryService"](
        (result.address, result.port), open_connection=dial_plane.dial,
        auxiliary_metadata=result.auxiliary_metadata)
    stack.push_async_callback(rsd.close)
    await rsd.connect()
    return rsd, result.client.wait_closed


async def acquire_provider(runtime, stack, udid, connection_type, rsd_address):
    e = runtime["exceptions"]
    if rsd_address is not None:
        host, port = rsd_address
        provider = runtime["RemoteServiceDiscoveryService"](
            (host, port), handshake_uuid=runtime["rsd_handshake_uuid"](host))
        stack.push_async_callback(provider.close)
        await provider.connect()
        verify_identity(provider, udid)
        return DeviceProvider(provider, "manual-rsd")

    lockdown = None
    try:
        lockdown = await runtime["create_using_usbmux"](
            serial=udid, connection_type="USB" if connection_type == "usb" else "Network",
            autopair=connection_type == "usb")
    except e.DeviceNotFoundError:
        if connection_type != "wifi":
            raise
    if lockdown is not None:
        lockdown_owner = AsyncExitStack()
        lockdown_owner.push_async_callback(lockdown.close)
        stack.push_async_callback(lockdown_owner.aclose)
        verify_identity(lockdown, udid)
        if int(lockdown.product_version.split(".")[0]) < 17:
            return DeviceProvider(lockdown, "lockdown-" + connection_type)
        if connection_type == "usb":
            try:
                proxy = await runtime["tunnel_service"].CoreDeviceTunnelProxy.create(lockdown)
            except e.InvalidServiceError:
                await lockdown_owner.aclose()
                provider = await stack.enter_async_context(runtime["NativeRemotedTunnel"](serial=udid))
                verify_identity(provider, udid)
                return DeviceProvider(provider, "native")
            stack.push_async_callback(proxy.close)
            await bootstrap_usb_pairing(runtime, lockdown)
            provider, wait_closed = await open_userspace(runtime, stack, proxy, "tcp")
            verify_identity(provider, udid)
            return DeviceProvider(provider, "userspace-usb", wait_closed)

    if not has_wifi_pair_record(runtime, udid):
        raise WorkerError("pairing_required", PAIRING_GUIDANCE)
    failures = []
    for protocol in ("tcp", "quic"):
        # A failed attempt releases every provider before discovery is repeated for this UDID.
        attempt = AsyncExitStack()
        await attempt.__aenter__()
        try:
            providers = await runtime["tunnel_service"].get_remote_pairing_tunnel_services(udid=udid)
            provider_owners = []
            for provider in providers:
                owner = AsyncExitStack()
                owner.push_async_callback(provider.close)
                attempt.push_async_callback(owner.aclose)
                provider_owners.append((provider, owner))
            matches = [p for p in providers if p.remote_identifier == udid]
            if not matches:
                raise WorkerError("wifi_unavailable", "找不到此裝置的 Wi‑Fi 連線，請確認同一網路。")
            selected = matches[0]
            for provider, owner in provider_owners:
                if provider is not selected:
                    await owner.aclose()
            provider, wait_closed = await open_userspace(runtime, attempt, selected, protocol)
            verify_identity(provider, udid)
        except TunnelAttemptError as exc:
            failures.append(exc.__cause__)
            await attempt.aclose()
            if protocol == "tcp":
                continue
            for failure in failures:
                LOG.error("Wi-Fi tunnel establishment failed: %r", failure)
            summaries = "；".join(f"{label}：{error_from_exception(failure)}"
                                  for label, failure in zip(("TCP", "QUIC"), failures))
            raise WorkerError("transport_unavailable", summaries) from exc
        except BaseException:
            await attempt.aclose()
            raise
        else:
            stack.push_async_callback(attempt.aclose)
            return DeviceProvider(provider, "userspace-wifi", wait_closed)

@asynccontextmanager
async def open_device_provider(udid, connection_type, rsd_address, *, runtime=None):
    runtime = runtime or load_runtime()
    tunnel_service = runtime["tunnel_service"]
    previous = tunnel_service.USE_USERSPACE_TUNNEL
    tunnel_service.USE_USERSPACE_TUNNEL = True
    try:
        async with AsyncExitStack() as stack:
            async with asyncio.timeout(TUNNEL_TIMEOUT):
                device = await acquire_provider(runtime, stack, udid, connection_type, rsd_address)
            yield device
    finally:
        tunnel_service.USE_USERSPACE_TUNNEL = previous


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def parse_request(raw, last_id):
    request_id = None
    try:
        if raw is None or len(raw) > MAX_LINE:
            raise ValueError()
        request = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_fields)
        if not isinstance(request, dict):
            raise ValueError()
        candidate = request.get("id")
        if type(candidate) is int and candidate > 0:
            request_id = candidate
        if request_id is None or request_id <= last_id:
            raise ValueError()
        op = request.get("op")
        fields = {"id", "op", "latitude", "longitude"} if op == "set" else {"id", "op"}
        if op not in ("set", "clear", "start-stream", "stop-stream", "quit") or set(request) != fields:
            raise ValueError()
    except (ValueError, UnicodeError, TypeError, RecursionError):
        raise WorkerError("invalid_request", "無效的定位請求。", request_id) from None
    if op == "set":
        lat, lon = request["latitude"], request["longitude"]
        if (type(lat) not in (int, float) or type(lon) not in (int, float)
                or not -90 <= lat <= 90 or not -180 <= lon <= 180
                or not math.isfinite(lat) or not math.isfinite(lon)):
            raise WorkerError("invalid_coordinate", "座標無效。", request_id)
    return request


async def read_line(reader):
    """Discard an oversized line in bounded chunks, never interpreting its suffix."""
    oversized = False
    while True:
        try:
            line = await reader.readuntil(b"\n")
            if oversized or len(line) > MAX_LINE:
                return None
            return line
        except asyncio.LimitOverrunError as exc:
            oversized = True
            await reader.readexactly(exc.consumed)
        except asyncio.IncompleteReadError as exc:
            if oversized or exc.partial:
                return None
            return b""


async def command_loop(reader, service, emit, *, state=None):
    state = state if state is not None else {}
    last_id = 0
    while True:
        raw = await read_line(reader)
        if raw == b"":
            return
        request_id = None
        try:
            request = parse_request(raw, last_id)
            request_id = request["id"]
            last_id = request_id
            op = request["op"]
            if op == "quit":
                state["quit"] = True
            async with asyncio.timeout(COMMAND_TIMEOUT):
                if op == "set":
                    await service.set(request["latitude"], request["longitude"])
                elif op in ("clear", "quit"):
                    await service.clear()
                elif op == "start-stream":
                    state["streaming"] = True
                elif op == "stop-stream":
                    state["streaming"] = False
            emit({"event": "ack", "id": request_id})
            if op == "quit":
                return
        except WorkerError as exc:
            error = error_from_exception(exc, request_id if request_id is not None else exc.request_id)
            if error.request_id is not None:
                last_id = max(last_id, error.request_id)
            emit(error.event())
            if error.fatal or state.get("quit"):
                state["fatal"] = True
                return
        except Exception as exc:
            LOG.exception("Location command failed")
            error = error_from_exception(exc, request_id, fatal=isinstance(exc, TimeoutError))
            emit(error.event())
            if error.fatal or op == "quit":
                state["fatal"] = True
                return


async def watch_transport(wait_closed):
    try:
        await wait_closed()
    except asyncio.CancelledError:
        raise
    except Exception:
        LOG.exception("Device transport closed with error")
    raise WorkerError("transport_lost", "裝置連線已中斷。", fatal=True)


async def cancel_tasks(tasks):
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


async def run_session(arguments, reader, emit, *, runtime=None):
    watchers = []
    state = {}
    service = None
    try:
        runtime = runtime or load_runtime()
        emit({"event": "stage", "message": "建立裝置連線"})
        async with open_device_provider(arguments.udid, arguments.connection_type, arguments.rsd, runtime=runtime) as device:
            provider = device.provider
            async with AsyncExitStack() as stack:
                try:
                    if device.wait_closed is not None:
                        watchers.append(asyncio.create_task(watch_transport(device.wait_closed)))
                    async def setup():
                        nonlocal service
                        # Validation has one 25-second budget shared by query and DVT setup.
                        remaining = VALIDATION_TIMEOUT
                        emit({"event": "stage", "message": "檢查開發者模式"})
                        started = asyncio.get_running_loop().time()
                        async with asyncio.timeout(remaining):
                            mounter = runtime["MobileImageMounterService"](lockdown=provider)
                            async with AsyncExitStack() as mounter_stack:
                                mounter_stack.push_async_callback(mounter.close)
                                try:
                                    enabled = await mounter.query_developer_mode_status()
                                except (runtime["exceptions"].MessageNotSupportedError,
                                        runtime["exceptions"].UnsupportedCommandError):
                                    enabled = True
                                if not enabled:
                                    raise WorkerError("developer_mode_disabled", "請在 iPhone「設定 → 隱私權與安全性」開啟開發者模式，重新啟動並確認後重試。")
                        remaining -= asyncio.get_running_loop().time() - started
                        emit({"event": "stage", "message": "掛載開發者映像"})
                        async with asyncio.timeout(MOUNT_TIMEOUT):
                            try:
                                await runtime["auto_mount"](provider)
                            except runtime["exceptions"].AlreadyMountedError:
                                pass
                        emit({"event": "stage", "message": "驗證定位服務"})
                        async with asyncio.timeout(remaining):
                            mode = "legacy"
                            if int(provider.product_version.split(".")[0]) >= 17:
                                dvt = runtime["DvtProvider"](provider)
                                stack.push_async_callback(dvt.close)
                                try:
                                    await dvt.connect()
                                except runtime["exceptions"].InvalidServiceError:
                                    await dvt.close()
                                else:
                                    service = runtime["LocationSimulation"](dvt)
                                    await service.connect()
                                    mode = "dvt"
                                    watchers.append(asyncio.create_task(watch_transport(dvt.dtx.wait_disconnected)))
                            if service is None:
                                service = runtime["DtSimulateLocation"](provider)
                            await service.clear()
                            name = provider.all_values.get("DeviceName") or await provider.get_value(key="DeviceName")
                            for watcher in watchers:
                                if watcher.done():
                                    watcher.result()
                            emit({"event": "ready", "version": 1, "udid": provider.udid,
                                  "deviceName": str(name or provider.udid), "transport": device.transport,
                                  "mode": mode, "euid": os.geteuid()})
                    setup_task = asyncio.create_task(setup())
                    try:
                        done, _ = await asyncio.wait([setup_task, *watchers], return_when=asyncio.FIRST_COMPLETED)
                        for task in done:
                            task.result()
                    finally:
                        if not setup_task.done():
                            await cancel_tasks([setup_task])
                    commands = asyncio.create_task(command_loop(reader, service, emit, state=state))
                    try:
                        done, _ = await asyncio.wait([commands, *watchers], return_when=asyncio.FIRST_COMPLETED)
                        for task in done:
                            task.result()
                    finally:
                        await cancel_tasks([commands])
                finally:
                    await cancel_tasks(watchers)
                    if service is not None and not state.get("quit"):
                        try:
                            async with asyncio.timeout(COMMAND_TIMEOUT):
                                await service.clear()
                        except Exception as exc:
                            LOG.exception("Disconnect clear failed")
                            emit(error_from_exception(exc, fatal=False).event())
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        LOG.exception("Device worker failed")
        emit(error_from_exception(exc, fatal=True).event())
        return 1
    return 1 if state.get("fatal") else 0


async def run_worker(arguments, emit):
    loop = asyncio.get_running_loop()
    stopped = asyncio.Event()
    reader = asyncio.StreamReader(limit=MAX_LINE)
    class InputProtocol(asyncio.StreamReaderProtocol):
        def eof_received(self):
            stopped.set()
            return super().eof_received()

        def connection_lost(self, exc):
            stopped.set()
            super().connection_lost(exc)

    transport, _ = await loop.connect_read_pipe(lambda: InputProtocol(reader), sys.stdin.buffer)
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stopped.set)
    stop_task = asyncio.create_task(stopped.wait())
    session = asyncio.create_task(run_session(arguments, reader, emit))
    try:
        done, _ = await asyncio.wait([session, stop_task], return_when=asyncio.FIRST_COMPLETED)
        return session.result() if session in done else 0
    finally:
        await cancel_tasks([session, stop_task])
        transport.close()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.remove_signal_handler(sig)


def parse_arguments(argv=None):
    parser = argparse.ArgumentParser(description="不需管理員權限的每裝置定位 worker")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--check-runtime", action="store_true")
    parser.add_argument("--udid")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--connection-type", choices=("usb", "wifi"))
    group.add_argument("--rsd", nargs=2, metavar=("HOST", "PORT"))
    args = parser.parse_args(argv)
    if args.version or args.check_runtime:
        return args
    if args.udid is not None and not args.udid.strip():
        parser.error("UDID 不可空白")
    if args.rsd is not None:
        try:
            host, port = args.rsd
            port = int(port)
            if not host.strip() or not 1 <= port <= 65535:
                raise ValueError()
            args.rsd = (host, port)
        except ValueError:
            parser.error("RSD 需指定非空主機與 1…65535 的連接埠")
    elif not args.udid:
        parser.error("自動連線必須指定 --udid")
    args.connection_type = args.connection_type or "usb"
    return args


def main(argv=None):
    arguments = parse_arguments(argv)
    protocol_output = sys.stdout
    def emit(event):
        protocol_output.write(json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
        protocol_output.flush()
    logging.basicConfig(stream=sys.stderr, level=logging.INFO)
    # Upstream diagnostic prints must never become protocol records.
    with redirect_stdout(sys.stderr):
        if arguments.version:
            protocol_output.write(VERSION + "\n")
            return 0
        if arguments.check_runtime:
            try:
                load_runtime()
            except Exception:
                LOG.exception("執行環境檢查失敗")
                return 1
            protocol_output.write(json.dumps({"pymobiledevice3": VERSION, "userspace": True, "dvt": True}) + "\n")
            return 0
        if os.geteuid() == 0:
            print("定位 worker 不可由 root 執行；請以一般使用者啟動，不需要管理員密碼。", file=sys.stderr)
            return 1
        return asyncio.run(run_worker(arguments, emit))


if __name__ == "__main__":
    raise SystemExit(main())
