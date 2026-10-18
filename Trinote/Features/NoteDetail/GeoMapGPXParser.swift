import Foundation

/// Reads GPX 1.0/1.1 files for geo map notes: the lines to draw, the waypoints to pin, and the
/// figures shown in the detail panel (distance, climb, duration).
///
/// Every `<trk>` and every `<rte>` becomes one journey. Distances are great-circle distances
/// summed within each segment, so the gap between two track segments is never counted.
enum GeoMapGPXParser {

    struct Point: Sendable {
        var lat: Double
        var lon: Double
        var elevation: Double?
        var time: Date?
    }

    struct Journey: Sendable {
        enum Kind: String, Sendable { case track, route }
        let kind: Kind
        var name: String?
        let segments: [[Point]]
    }

    struct ElevationStats: Sendable {
        let min: Double
        let max: Double
        let gain: Double
        let loss: Double
    }

    struct TimeStats: Sendable {
        let start: Date
        let end: Date
        let duration: TimeInterval
    }

    struct JourneySummary: Sendable {
        let kind: Journey.Kind
        var name: String?
        let distance: Double
    }

    struct TrackSegment: Sendable, Hashable {
        var name: String?
        /// `[longitude, latitude]` pairs for MapLibre.
        let coordinates: [[Double]]
    }

    struct Stats: Sendable {
        var name: String?
        var description: String?
        let trackCount: Int
        let routeCount: Int
        let segmentCount: Int
        let pointCount: Int
        var distance: Double
        var elevation: ElevationStats?
        var time: TimeStats?
        var journeys: [JourneySummary]
    }

    /// Elevation changes smaller than this are treated as GPS jitter, not as climbing.
    private static let climbThreshold = 5.0
    private static let meanEarthRadius = 6_371_008.8

    // MARK: - Public API

    static func parse(_ xml: String) -> Stats? {
        guard let file = GPXFile(xml), !file.journeys.isEmpty else { return nil }

        var summaries: [JourneySummary] = []
        var climb = ClimbCounter(threshold: climbThreshold)
        var lowest: Double?
        var highest: Double?
        var earliest: Date?
        var latest: Date?

        for journey in file.journeys {
            let length = journey.segments.reduce(0) { $0 + pathLength($1) }
            summaries.append(JourneySummary(kind: journey.kind, name: journey.name, distance: length))

            for segment in journey.segments {
                climb.startSegment()
                for point in segment {
                    if let elevation = point.elevation {
                        climb.add(elevation)
                        lowest = Swift.min(lowest ?? elevation, elevation)
                        highest = Swift.max(highest ?? elevation, elevation)
                    }
                    if let time = point.time {
                        earliest = Swift.min(earliest ?? time, time)
                        latest = Swift.max(latest ?? time, time)
                    }
                }
            }
        }

        var stats = Stats(
            name: file.name,
            description: file.description,
            trackCount: file.journeys.filter { $0.kind == .track }.count,
            routeCount: file.journeys.filter { $0.kind == .route }.count,
            segmentCount: file.trackSegmentCount,
            pointCount: file.journeys.reduce(0) { total, journey in
                total + journey.segments.reduce(0) { $0 + $1.count }
            },
            distance: summaries.reduce(0) { $0 + $1.distance },
            journeys: summaries
        )
        if let lowest, let highest {
            stats.elevation = ElevationStats(min: lowest, max: highest, gain: climb.gain, loss: climb.loss)
        }
        if let earliest, let latest {
            stats.time = TimeStats(start: earliest, end: latest, duration: latest.timeIntervalSince(earliest))
        }
        return stats
    }

    /// Returns track lines as `[longitude, latitude]` coordinate pairs for MapLibre.
    static func readTrackLines(from xml: String) -> [[[Double]]] {
        readTrackSegments(from: xml).map(\.coordinates)
    }

    /// Track/route segment names aligned with `readTrackLines(from:)`.
    static func readLineNames(from xml: String) -> [String] {
        readTrackSegments(from: xml).map { $0.name ?? "" }
    }

    /// Name of the first track that has one.
    static func readFirstTrackName(from xml: String) -> String? {
        GPXFile(xml)?.journeys.first { $0.kind == .track && $0.name != nil }?.name
    }

    /// Display label for a zoomed-out GPX mark: first track name, then file `<name>`, then note title.
    static func summaryTitle(gpxXML: String, noteTitle: String) -> String {
        let file = GPXFile(gpxXML)
        if let name = file?.journeys.first(where: { $0.kind == .track && $0.name != nil })?.name {
            return name
        }
        if let name = file?.name { return name }
        let trimmed = noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? noteTitle : trimmed
    }

    /// One drawable line per track segment and per route, each with at least two points.
    static func readTrackSegments(from xml: String) -> [TrackSegment] {
        guard let file = GPXFile(xml) else { return [] }
        return file.journeys.flatMap { journey in
            journey.segments
                .filter { $0.count >= 2 }
                .map { TrackSegment(name: journey.name, coordinates: $0.map { [$0.lon, $0.lat] }) }
        }
    }

    /// GPX `<wpt>` elements for map marks.
    static func readWaypoints(from xml: String) -> [GeoMapWaypoint] {
        GPXFile(xml)?.waypoints ?? []
    }

    // MARK: - Geometry

    private static func pathLength(_ points: [Point]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + greatCircleDistance($1.0, $1.1) }
    }

    /// Haversine distance in metres.
    private static func greatCircleDistance(_ from: Point, _ to: Point) -> Double {
        let radians = Double.pi / 180
        let phi1 = from.lat * radians
        let phi2 = to.lat * radians
        let halfDeltaPhi = (to.lat - from.lat) * radians / 2
        let halfDeltaLambda = (to.lon - from.lon) * radians / 2
        let h = sin(halfDeltaPhi) * sin(halfDeltaPhi)
            + cos(phi1) * cos(phi2) * sin(halfDeltaLambda) * sin(halfDeltaLambda)
        return 2 * meanEarthRadius * asin(Swift.min(1, h.squareRoot()))
    }

    /// Counts climbing and descending, ignoring wobbles below `threshold`: a change only counts
    /// once the elevation has moved at least that far from the last counted level.
    private struct ClimbCounter {
        let threshold: Double
        private(set) var gain = 0.0
        private(set) var loss = 0.0
        private var reference: Double?

        init(threshold: Double) { self.threshold = threshold }

        mutating func startSegment() { reference = nil }

        mutating func add(_ elevation: Double) {
            guard let level = reference else { reference = elevation; return }
            let change = elevation - level
            guard abs(change) >= threshold else { return }
            if change > 0 { gain += change } else { loss -= change }
            reference = elevation
        }
    }

    // MARK: - XML

    /// The parts of a GPX document the map uses, read with `XMLParser`.
    private struct GPXFile {
        var name: String?
        var description: String?
        var journeys: [Journey] = []
        var waypoints: [GeoMapWaypoint] = []
        var trackSegmentCount = 0

        init?(_ xml: String) {
            let reader = Reader()
            let parser = XMLParser(data: Data(xml.utf8))
            parser.shouldProcessNamespaces = true
            parser.delegate = reader
            guard parser.parse() || !reader.file.journeys.isEmpty || !reader.file.waypoints.isEmpty else {
                return nil
            }
            self = reader.file
        }

        fileprivate init() {}
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var file = GPXFile()

        private var path: [String] = []
        private var text = ""
        private var journeyKind: Journey.Kind?
        private var journeyName: String?
        private var segments: [[Point]] = []
        private var segment: [Point] = []
        private var point: Point?
        private var waypoint: (lat: Double, lon: Double, name: String?)?

        private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        private static let iso = Date.ISO8601FormatStyle()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            path.append(elementName)
            text = ""
            switch elementName {
            case "trk":
                beginJourney(.track)
            case "rte":
                beginJourney(.route)
            case "trkseg":
                segment = []
            case "trkpt", "rtept":
                point = Self.coordinate(attributes).map { Point(lat: $0.lat, lon: $0.lon) }
            case "wpt":
                waypoint = Self.coordinate(attributes).map { ($0.lat, $0.lon, nil) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.dropLast().last
            switch elementName {
            case "ele":
                point?.elevation = Double(value)
            case "time" where point != nil:
                point?.time = (try? Self.isoWithFraction.parse(value)) ?? (try? Self.iso.parse(value))
            case "name" where !value.isEmpty:
                assignName(value, parent: parent)
            case "desc" where !value.isEmpty && (parent == "metadata" || parent == "gpx"):
                if file.description == nil { file.description = value }
            case "trkpt":
                if let point { segment.append(point) }
                point = nil
            case "rtept":
                if let point { segment.append(point) }
                point = nil
            case "trkseg":
                file.trackSegmentCount += 1
                if !segment.isEmpty { segments.append(segment) }
                segment = []
            case "wpt":
                if let waypoint {
                    file.waypoints.append(GeoMapWaypoint(lng: waypoint.lon, lat: waypoint.lat, name: waypoint.name))
                }
                waypoint = nil
            case "trk", "rte":
                endJourney()
            default:
                break
            }
            path.removeLast()
            text = ""
        }

        private func assignName(_ name: String, parent: String?) {
            switch parent {
            case "trk", "rte":
                if journeyName == nil { journeyName = name }
            case "wpt":
                waypoint?.name = name
            case "metadata", "gpx":
                if file.name == nil { file.name = name }
            default:
                break
            }
        }

        private func beginJourney(_ kind: Journey.Kind) {
            journeyKind = kind
            journeyName = nil
            segments = []
            segment = []
        }

        private func endJourney() {
            guard let kind = journeyKind else { return }
            // A route has no segments of its own, and some tracks put their points straight
            // under <trk>; either way the loose points form one segment.
            if !segment.isEmpty { segments.append(segment) }
            if !segments.isEmpty {
                file.journeys.append(Journey(kind: kind, name: journeyName, segments: segments))
            }
            journeyKind = nil
            segments = []
            segment = []
        }

        private static func coordinate(_ attributes: [String: String]) -> (lat: Double, lon: Double)? {
            guard let lat = attributes["lat"].flatMap(Double.init),
                  let lon = attributes["lon"].flatMap(Double.init),
                  (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
            return (lat, lon)
        }
    }
}
