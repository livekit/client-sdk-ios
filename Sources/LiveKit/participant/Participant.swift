import Foundation
import WebRTC

public class Participant: MulticastDelegate<ParticipantDelegate> {

    public let sid: Sid
    public internal(set) var identity: String?
    public internal(set) var audioLevel: Float = 0.0
    public internal(set) var isSpeaking: Bool = false {
        didSet {
            guard oldValue != isSpeaking else { return }
            notify { $0.participant(self, didUpdate: self.isSpeaking) }
            // relavent event for Room doesn't exist yet...
        }
    }

    public internal(set) var metadata: String? {
        didSet {
            guard oldValue != metadata else { return }
            notify { $0.participant(self, didUpdate: self.metadata) }
            room?.notify { $0.room(self.room!, participant: self, didUpdate: self.metadata) }
        }
    }

    public internal(set) var connectionQuality: ConnectionQuality = .unknown {
        didSet {
            guard oldValue != connectionQuality else { return }
            notify { $0.participant(self, didUpdate: self.connectionQuality) }
            room?.notify { $0.room(self.room!, participant: self, didUpdate: self.connectionQuality) }
        }
    }

    public private(set) var joinedAt: Date?
    public internal(set) var tracks = [String: TrackPublication]()

    public var audioTracks: [String: TrackPublication] {
        tracks.filter { $0.value.kind == .audio }
    }

    public var videoTracks: [String: TrackPublication] {
        tracks.filter { $0.value.kind == .video }
    }

    var info: Livekit_ParticipantInfo?

    // reference to the Room this Participant belongs to
    weak var room: Room?

    public init(sid: String) {
        self.sid = sid
    }

    func addTrack(publication: TrackPublication) {
        tracks[publication.sid] = publication
        publication.track?.sid = publication.sid
    }

    func updateFromInfo(info: Livekit_ParticipantInfo) {
        identity = info.identity
        metadata = info.metadata
        joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        self.info = info
    }
}

// MARK: - Equality

extension Participant {

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(sid)
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Participant else {
            return false
        }
        return sid == other.sid
    }
}
