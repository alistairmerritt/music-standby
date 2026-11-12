import Foundation

/// Which relay the app talks to.
///
/// `relayURL` in the app's defaults wins, so a development relay can be used
/// without a rebuild:
///
///     defaults write com.alistairmerritt.MusicStandBy.Mac relayURL http://127.0.0.1:8787
///
/// Otherwise it's the host the build wrote into Info.plist as `MSBRelayHost`
/// (`scripts/build.sh` takes it from `MSB_RELAY_HOST` or
/// `~/.config/second-chair/relay-host`, so it never enters the repository),
/// over HTTPS. With neither, there is no relay.
public enum RelayEndpoint {
    public static let builtInHostKey = "MSBRelayHost"

    public static func url(override: String?, builtInHost: String?) -> URL? {
        if let override, let url = URL(string: override.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme == "https" || url.scheme == "http", url.host() != nil {
            return url
        }
        guard let host = builtInHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }),
              let url = URL(string: "https://\(host)"), url.host() == host
        else { return nil }
        return url
    }

    /// The relay for this app: its defaults, then its own Info.plist.
    public static func current(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> URL? {
        url(override: defaults.string(forKey: "relayURL"), builtInHost: bundle.object(forInfoDictionaryKey: builtInHostKey) as? String)
    }
}
