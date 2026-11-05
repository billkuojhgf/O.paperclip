import MapKit
import SwiftUI

enum PersistedMapRegionStore {
    static func loadCamera() -> MapCamera? {
        guard let values = UserDefaults.standard.array(forKey: "map.camera") as? [Double],
              values.count == 5, values.allSatisfy(\.isFinite), values[2] > 0 else { return nil }
        let center = CLLocationCoordinate2D(latitude: values[0], longitude: values[1])
        guard CLLocationCoordinate2DIsValid(center), (0...360).contains(values[3]),
              (0...90).contains(values[4]) else { return nil }
        return MapCamera(centerCoordinate: center, distance: values[2], heading: values[3], pitch: values[4])
    }

    static func load(defaults: UserDefaults = .standard) -> MKCoordinateRegion {
        let latitude = defaults.object(forKey: "map.center.lat") as? Double ?? AppConstants.Map.defaultLatitude
        let longitude = defaults.object(forKey: "map.center.lon") as? Double ?? AppConstants.Map.defaultLongitude
        let candidate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let center: CLLocationCoordinate2D
        if CLLocationCoordinate2DIsValid(candidate), latitude.isFinite, longitude.isFinite {
            center = candidate
        } else {
            center = CLLocationCoordinate2D(latitude: AppConstants.Map.defaultLatitude, longitude: AppConstants.Map.defaultLongitude)
        }
        func span(_ key: String) -> Double {
            let value = defaults.object(forKey: key) as? Double ?? AppConstants.Map.defaultSpanDelta
            guard value.isFinite else { return AppConstants.Map.defaultSpanDelta }
            return min(max(value, AppConstants.Map.minimumSpanDelta), AppConstants.Map.maximumSpanDelta)
        }
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span("map.span.lat"), longitudeDelta: span("map.span.lon")))
    }
}

public struct PurePointRenderEngine {
    static func renderState(
        for entries: [VisiblePurePoint],
        region: MKCoordinateRegion,
        padding: Double,
        limit: Int,
        activationCount: Int,
        wideSpanThreshold: Double
    ) -> PurePointRenderState {
        let validEntries = entries.filter {
            let coordinate = $0.point.coordinate
            return CLLocationCoordinate2DIsValid(coordinate) && coordinate.latitude.isFinite && coordinate.longitude.isFinite
        }
        guard !validEntries.isEmpty else { return .empty }

        let regionNorm = region
        let viewportFilteringNeeded = shouldViewportFilter(count: validEntries.count, region: regionNorm, activationCount: activationCount, wideSpanThreshold: wideSpanThreshold)
        let viewportEntries = viewportFilteringNeeded
            ? validEntries.filter { contains($0.point.coordinate, in: regionNorm, paddingFactor: padding) }
            : validEntries

        let rendered = cappedEntries(viewportEntries, limit: limit, region: regionNorm)
        return PurePointRenderState(
            points: rendered,
            totalMatchingCount: validEntries.count,
            viewportMatchingCount: viewportEntries.count,
            isViewportFiltered: viewportFilteringNeeded,
            isDensityLimited: viewportEntries.count > rendered.count
        )
    }

    // MARK: - Helpers moved from ContentView.swift
    static func shouldViewportFilter(count: Int, region: MKCoordinateRegion, activationCount: Int, wideSpanThreshold: Double) -> Bool {
        count > activationCount || region.span.latitudeDelta > wideSpanThreshold || region.span.longitudeDelta > wideSpanThreshold
    }

    static func contains(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion, paddingFactor: Double = 0) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate), coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return false }
        let latPadding = region.span.latitudeDelta * paddingFactor
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2) - latPadding
        let maxLat = region.center.latitude + (region.span.latitudeDelta / 2) + latPadding
        let halfLongitude = region.span.longitudeDelta * (0.5 + paddingFactor)
        let longitudeDistance = abs((coordinate.longitude - region.center.longitude).truncatingRemainder(dividingBy: 360))
        let wrappedDistance = min(longitudeDistance, 360 - longitudeDistance)
        return coordinate.latitude >= minLat && coordinate.latitude <= maxLat && wrappedDistance <= halfLongitude
    }

    static func cappedEntries(_ entries: [VisiblePurePoint], limit: Int, region: MKCoordinateRegion) -> [VisiblePurePoint] {
        guard limit > 0 else { return [] }
        guard entries.count > limit else { return entries }
        let latSpan = max(region.span.latitudeDelta, AppConstants.Map.minimumSpanDelta)
        let lonSpan = max(region.span.longitudeDelta, AppConstants.Map.minimumSpanDelta)
        let aspectRatio = max(lonSpan / latSpan, 0.5)
        let columnCount = max(1, Int((Double(limit) * aspectRatio).squareRoot().rounded(.up)))
        let rowCount = max(1, Int(ceil(Double(limit) / Double(columnCount))))
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2)
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2)

        var bucketed: [String: VisiblePurePoint] = [:]
        for entry in entries {
            let coordinate = entry.point.coordinate
            let normalizedX = (coordinate.longitude - minLon) / lonSpan
            let normalizedY = (coordinate.latitude - minLat) / latSpan
            let x = min(columnCount - 1, max(0, Int(floor(normalizedX * Double(columnCount)))))
            let y = min(rowCount - 1, max(0, Int(floor(normalizedY * Double(rowCount)))))
            let key = "\(x):\(y)"
            if bucketed[key] == nil {
                bucketed[key] = entry
            }
        }

        var result = entries.filter { bucketed[bucketKey(for: $0.point.coordinate, region: region, columns: columnCount, rows: rowCount)]?.id == $0.id }
        if result.count > limit { result = Array(result.prefix(limit)) }
        if result.count == limit { return result }

        let existingIDs = Set(result.map { $0.id })
        let remaining = entries.filter { !existingIDs.contains($0.id) }
        result.append(contentsOf: remaining.prefix(limit - result.count))
        return result
    }

    static func bucketKey(for coordinate: CLLocationCoordinate2D, region: MKCoordinateRegion, columns: Int, rows: Int) -> String {
        let latSpan = max(region.span.latitudeDelta, AppConstants.Map.minimumSpanDelta)
        let lonSpan = max(region.span.longitudeDelta, AppConstants.Map.minimumSpanDelta)
        let minLat = region.center.latitude - (region.span.latitudeDelta / 2)
        let minLon = region.center.longitude - (region.span.longitudeDelta / 2)
        let normalizedX = (coordinate.longitude - minLon) / lonSpan
        let normalizedY = (coordinate.latitude - minLat) / latSpan
        let x = min(columns - 1, max(0, Int(floor(normalizedX * Double(columns)))))
        let y = min(rows - 1, max(0, Int(floor(normalizedY * Double(rows)))))
        return "\(x):\(y)"
    }

    static func safeMapColor(for category: ShuangbeiPurePointCategory?) -> Color {
        (category?.color ?? .blue).opacity(0.98)
    }
}
