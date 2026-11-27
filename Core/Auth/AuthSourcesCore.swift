import Foundation

// Auth sources shared by the Mac and iOS apps (docs/features/auth-autofill.md → Sources):
// registrable domains from the bundled public suffix list, and issuer names mapped to sites.

// MARK: - Public suffix list

/// The registrable domain of a host ("accounts.google.com" → "google.com", "www.bbc.co.uk" →
/// "bbc.co.uk"), from the bundled, trimmed public suffix list.
nonisolated struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    init(text: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !line.isEmpty, !line.hasPrefix("//") else { continue }
            let rule = line.lowercased()
            if rule.hasPrefix("!") {
                exceptions.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcards.insert(String(rule.dropFirst(2)))
            } else {
                rules.insert(rule)
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    static let shared: PublicSuffixList = {
        let bundles = [Bundle.main, Bundle(for: BundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "PublicSuffixList", withExtension: "dat"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return PublicSuffixList(text: text)
            }
        }
        Log.app.error("PublicSuffixList.dat is missing from the bundle")
        return PublicSuffixList(text: "")
    }()

    private final class BundleMarker {}

    /// The public suffix of `host` ("co.uk" for "www.bbc.co.uk"). Unlisted TLDs fall to the
    /// default rule: the last label.
    func publicSuffix(of host: String) -> String? {
        let labels = Self.labels(of: host)
        guard !labels.isEmpty else { return nil }
        // Longest matching rule wins; an exception rule beats everything and means "one label less".
        for count in stride(from: labels.count, through: 1, by: -1) {
            let candidate = labels.suffix(count).joined(separator: ".")
            if exceptions.contains(candidate) { return labels.suffix(count - 1).joined(separator: ".") }
            if rules.contains(candidate) { return candidate }
            if count >= 2, wildcards.contains(labels.suffix(count - 1).joined(separator: ".")) { return candidate }
        }
        return labels.last
    }

    /// The suffix plus one label; nil when the host is itself a public suffix.
    func registrableDomain(of host: String) -> String? {
        let labels = Self.labels(of: host)
        guard let suffix = publicSuffix(of: host) else { return nil }
        let suffixCount = suffix.split(separator: ".").count
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }

    private static func labels(of host: String) -> [String] {
        var host = host.lowercased().trimmingCharacters(in: .whitespaces)
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return labels.contains(where: \.isEmpty) ? [] : labels
    }
}

// MARK: - Sources

/// What an item is grouped under: a site's registrable domain, or (for an authenticator whose
/// issuer isn't a known site) its issuer's name.
nonisolated enum AuthSource: Hashable, Sendable, Comparable {
    case domain(String)
    case issuer(String)

    var key: String {
        switch self {
        case .domain(let domain): domain
        case .issuer(let name): "issuer:" + name.lowercased()
        }
    }

    var name: String {
        switch self {
        case .domain(let domain): domain
        case .issuer(let name): name
        }
    }

    var domain: String? {
        if case .domain(let domain) = self { return domain }
        return nil
    }

    static func < (lhs: AuthSource, rhs: AuthSource) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// The host of a site as typed or imported: a URL, or a bare host ("google.com", "google.com/login").
    static func host(ofSite site: String) -> String? {
        let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased(), !host.isEmpty, !host.contains(" ")
        else { return nil }
        return host
    }

    /// The registrable domain of a site; an IP address or a single-label host (localhost) is its own.
    static func domain(ofSite site: String, list: PublicSuffixList = .shared) -> String? {
        guard let host = host(ofSite: site) else { return nil }
        if host.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" || $0 == "[" || $0 == "]" }) { return host }
        return list.registrableDomain(of: host) ?? host
    }

    /// Every distinct domain of a list of sites, in order.
    static func domains(ofSites sites: [String], list: PublicSuffixList = .shared) -> [String] {
        var seen = Set<String>()
        return sites.compactMap { domain(ofSite: $0, list: list) }.filter { seen.insert($0).inserted }
    }
}

// MARK: - Issuers

/// Common authenticator issuers and their sites. Issuers are matched without case, spaces or
/// punctuation ("Battle.net" → "battlenet"), then by their first word ("Google Workspace" → "google").
nonisolated enum IssuerDomains {
    static func domain(for issuer: String, list: PublicSuffixList = .shared) -> String? {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        // An issuer that's a host already ("accounts.google.com").
        if trimmed.contains("."), !trimmed.contains(" "), let domain = AuthSource.domain(ofSite: trimmed, list: list),
           domain.contains(".") {
            if let mapped = table[normalized(trimmed)] { return mapped }
            return domain
        }
        if let mapped = table[normalized(trimmed)] { return mapped }
        // Short first words ("X", "Max", "Box") are too ambiguous to stand for the whole issuer.
        if let first = trimmed.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" || $0 == "(" }).first,
           first.count >= 4, let mapped = table[normalized(String(first))] {
            return mapped
        }
        return nil
    }

    static func normalized(_ issuer: String) -> String {
        String(issuer.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    static let table: [String: String] = [
        // Big tech and accounts
        "google": "google.com", "gmail": "google.com", "googleworkspace": "google.com", "gsuite": "google.com",
        "youtube": "youtube.com", "microsoft": "microsoft.com", "microsoftaccount": "microsoft.com",
        "outlook": "microsoft.com", "outlookcom": "microsoft.com", "hotmail": "microsoft.com", "office365": "microsoft.com",
        "microsoft365": "microsoft.com", "azure": "microsoft.com", "azuread": "microsoft.com", "entraid": "microsoft.com",
        "xbox": "xbox.com", "apple": "apple.com", "appleid": "apple.com", "icloud": "icloud.com",
        "amazon": "amazon.com", "aws": "amazon.com", "amazonwebservices": "amazon.com", "awsiam": "amazon.com",
        "facebook": "facebook.com", "meta": "meta.com", "instagram": "instagram.com", "whatsapp": "whatsapp.com",
        "twitter": "x.com", "x": "x.com", "linkedin": "linkedin.com", "reddit": "reddit.com", "discord": "discord.com",
        "slack": "slack.com", "zoom": "zoom.us", "dropbox": "dropbox.com", "box": "box.com", "notion": "notion.so",
        "evernote": "evernote.com", "trello": "trello.com", "asana": "asana.com", "figma": "figma.com",
        "adobe": "adobe.com", "adobeid": "adobe.com", "canva": "canva.com", "telegram": "telegram.org",
        "tiktok": "tiktok.com", "snapchat": "snapchat.com", "pinterest": "pinterest.com", "tumblr": "tumblr.com",
        "medium": "medium.com", "substack": "substack.com", "patreon": "patreon.com", "twitch": "twitch.tv",
        "yahoo": "yahoo.com", "aol": "aol.com", "zoho": "zoho.com", "samsung": "samsung.com", "xiaomi": "mi.com",
        "huawei": "huawei.com", "nvidia": "nvidia.com", "intel": "intel.com", "amd": "amd.com",
        "oracle": "oracle.com", "ibm": "ibm.com", "sap": "sap.com", "vmware": "vmware.com", "citrix": "citrix.com",
        "openai": "openai.com", "chatgpt": "openai.com", "anthropic": "anthropic.com", "claude": "anthropic.com",
        "huggingface": "huggingface.co", "replicate": "replicate.com",
        // Developer tools and hosting
        "github": "github.com", "gitlab": "gitlab.com", "bitbucket": "bitbucket.org", "atlassian": "atlassian.com",
        "jira": "atlassian.com", "confluence": "atlassian.com", "codeberg": "codeberg.org", "sourcehut": "sr.ht",
        "npm": "npmjs.com", "npmjs": "npmjs.com", "pypi": "pypi.org", "rubygems": "rubygems.org",
        "dockerhub": "docker.com", "docker": "docker.com", "jetbrains": "jetbrains.com", "cloudflare": "cloudflare.com",
        "digitalocean": "digitalocean.com", "linode": "linode.com", "akamai": "akamai.com", "vultr": "vultr.com",
        "hetzner": "hetzner.com", "ovh": "ovh.com", "ovhcloud": "ovh.com", "heroku": "heroku.com",
        "vercel": "vercel.com", "netlify": "netlify.com", "flyio": "fly.io", "render": "render.com",
        "railway": "railway.app", "supabase": "supabase.com", "firebase": "google.com", "mongodb": "mongodb.com",
        "mongodbatlas": "mongodb.com", "sentry": "sentry.io", "datadog": "datadoghq.com", "newrelic": "newrelic.com",
        "pagerduty": "pagerduty.com", "twilio": "twilio.com", "sendgrid": "sendgrid.com", "mailchimp": "mailchimp.com",
        "mailgun": "mailgun.com", "postmark": "postmarkapp.com", "okta": "okta.com", "auth0": "auth0.com",
        "onelogin": "onelogin.com", "duo": "duo.com", "circleci": "circleci.com", "travisci": "travis-ci.com",
        "buildkite": "buildkite.com", "codecov": "codecov.io", "snyk": "snyk.io", "sonarcloud": "sonarcloud.io",
        "hashicorp": "hashicorp.com", "terraformcloud": "hashicorp.com", "grafana": "grafana.com",
        "elastic": "elastic.co", "algolia": "algolia.com", "segment": "segment.com", "mixpanel": "mixpanel.com",
        "amplitude": "amplitude.com", "posthog": "posthog.com", "hackerone": "hackerone.com", "bugcrowd": "bugcrowd.com",
        "tailscale": "tailscale.com", "zerotier": "zerotier.com", "ngrok": "ngrok.com", "expo": "expo.dev",
        "appstoreconnect": "apple.com", "googleplay": "google.com", "unity": "unity.com", "wordpress": "wordpress.com",
        "wordpresscom": "wordpress.com", "wix": "wix.com", "squarespace": "squarespace.com", "webflow": "webflow.com",
        "godaddy": "godaddy.com", "namecheap": "namecheap.com", "gandi": "gandi.net", "porkbun": "porkbun.com",
        "hover": "hover.com", "dnsimple": "dnsimple.com", "synology": "synology.com", "ubiquiti": "ui.com",
        "unifi": "ui.com", "plex": "plex.tv",
        // Work and productivity
        "salesforce": "salesforce.com", "hubspot": "hubspot.com", "intercom": "intercom.com", "zendesk": "zendesk.com",
        "freshworks": "freshworks.com", "freshdesk": "freshworks.com", "airtable": "airtable.com",
        "monday": "monday.com", "mondaycom": "monday.com", "clickup": "clickup.com", "linear": "linear.app",
        "miro": "miro.com", "loom": "loom.com", "calendly": "calendly.com", "docusign": "docusign.com",
        "hellosign": "dropbox.com", "gusto": "gusto.com", "rippling": "rippling.com", "deel": "deel.com",
        "intuit": "intuit.com", "quickbooks": "intuit.com", "turbotax": "intuit.com", "xero": "xero.com",
        "freshbooks": "freshbooks.com", "sevdesk": "sevdesk.de", "lexoffice": "lexoffice.de", "datev": "datev.de",
        "personio": "personio.com", "teamviewer": "teamviewer.com", "anydesk": "anydesk.com",
        // Passwords, mail and privacy
        "lastpass": "lastpass.com", "1password": "1password.com", "bitwarden": "bitwarden.com",
        "dashlane": "dashlane.com", "keeper": "keepersecurity.com", "proton": "proton.me", "protonmail": "proton.me",
        "protonvpn": "proton.me", "tutanota": "tuta.com", "tuta": "tuta.com", "fastmail": "fastmail.com",
        "gmx": "gmx.net", "webde": "web.de", "mailboxorg": "mailbox.org", "posteo": "posteo.de",
        "nordvpn": "nordvpn.com", "nordaccount": "nordaccount.com", "expressvpn": "expressvpn.com",
        "mullvad": "mullvad.net", "mega": "mega.nz", "pcloud": "pcloud.com", "backblaze": "backblaze.com",
        "wasabi": "wasabi.com", "kagi": "kagi.com",
        // Money
        "paypal": "paypal.com", "stripe": "stripe.com", "square": "squareup.com", "wise": "wise.com",
        "transferwise": "wise.com", "revolut": "revolut.com", "n26": "n26.com", "monzo": "monzo.com",
        "starling": "starlingbank.com", "coinbase": "coinbase.com", "binance": "binance.com", "kraken": "kraken.com",
        "gemini": "gemini.com", "bitstamp": "bitstamp.net", "bitfinex": "bitfinex.com", "cryptocom": "crypto.com",
        "kucoin": "kucoin.com", "okx": "okx.com", "bybit": "bybit.com", "bitpanda": "bitpanda.com",
        "robinhood": "robinhood.com", "etoro": "etoro.com", "interactivebrokers": "interactivebrokers.com",
        "ibkr": "interactivebrokers.com", "schwab": "schwab.com", "fidelity": "fidelity.com",
        "vanguard": "vanguard.com", "etrade": "etrade.com", "chase": "chase.com", "wellsfargo": "wellsfargo.com",
        "bankofamerica": "bankofamerica.com", "americanexpress": "americanexpress.com", "amex": "americanexpress.com",
        "capitalone": "capitalone.com", "discover": "discover.com", "citi": "citi.com", "hsbc": "hsbc.com",
        "barclays": "barclays.co.uk", "lloyds": "lloydsbank.com", "traderepublic": "traderepublic.com",
        "scalablecapital": "scalable.capital", "dkb": "dkb.de", "comdirect": "comdirect.de",
        "paddle": "paddle.com", "gumroad": "gumroad.com", "lemonsqueezy": "lemonsqueezy.com",
        "shopify": "shopify.com", "kickstarter": "kickstarter.com",
        // Shopping, travel, media
        "ebay": "ebay.com", "etsy": "etsy.com", "aliexpress": "aliexpress.com", "alibaba": "alibaba.com",
        "walmart": "walmart.com", "target": "target.com", "bestbuy": "bestbuy.com", "ikea": "ikea.com",
        "airbnb": "airbnb.com", "booking": "booking.com", "bookingcom": "booking.com", "expedia": "expedia.com",
        "uber": "uber.com", "lyft": "lyft.com", "doordash": "doordash.com", "deliveroo": "deliveroo.com",
        "wolt": "wolt.com", "netflix": "netflix.com", "spotify": "spotify.com", "hulu": "hulu.com",
        "disney": "disneyplus.com", "disneyplus": "disneyplus.com", "hbomax": "max.com", "max": "max.com",
        "tesla": "tesla.com", "usps": "usps.com", "ups": "ups.com", "fedex": "fedex.com", "dhl": "dhl.com",
        // Games
        "steam": "steampowered.com", "valve": "steampowered.com", "epicgames": "epicgames.com", "epic": "epicgames.com",
        "battlenet": "battle.net", "blizzard": "battle.net", "ea": "ea.com", "electronicarts": "ea.com",
        "ubisoft": "ubisoft.com", "riotgames": "riotgames.com", "riot": "riotgames.com", "nintendo": "nintendo.com",
        "playstation": "playstation.com", "psn": "playstation.com", "sony": "sony.com", "roblox": "roblox.com",
        "minecraft": "minecraft.net", "gog": "gog.com", "humblebundle": "humblebundle.com",
        // Government and identity
        "irs": "irs.gov", "logingov": "login.gov", "idme": "id.me", "elster": "elster.de",
        "finanzonline": "bmf.gv.at", "idaustria": "oesterreich.gv.at",
        // Regional
        "yandex": "yandex.ru", "vk": "vk.com", "mailru": "mail.ru", "line": "line.me", "kakao": "kakao.com",
        "naver": "naver.com", "wechat": "wechat.com", "qq": "qq.com", "rakuten": "rakuten.com", "mercari": "mercari.com",
    ]
}
