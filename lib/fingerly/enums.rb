# frozen_string_literal: true

# Named constants for the closed string sets the API sends.
#
# Every constant is the frozen wire string itself, so it compares equal to the
# field it names (+event.suspect_level == Fingerly::SuspectLevel::HIGH+) and
# the fields stay plain strings. A value the server adds after this SDK was
# released still arrives unchanged; it is only missing from +ALL+.
#
# Each module's +ALL+ is a frozen array of its values, in the order listed.
module Fingerly
  # Identifiers a trigger's +signal+ (and +group+) can hold.
  #
  # Event reads report each trigger under its signal group, such as +vpn+;
  # +visitor.suspect+ webhooks and the archived document's +risk.triggers+
  # carry the detector, such as +vpn_public+, with its group beside it. Many
  # groups share their detector's name, so each identifier is here once.
  #
  # Inside +module Fingerly+, this constant shadows Ruby's own +::Signal+.
  module Signal
    # Detectors every platform can produce.
    HIGH_ACTIVITY = "high_activity"
    TAMPERING = "tampering"
    DEVICE_FARM = "device_farm"
    DEVELOPER_TOOLS = "developer_tools"
    GEO_MISMATCH = "geo_mismatch"
    DEVICE_INCONSISTENT = "device_inconsistent"

    # Detectors derived from the address a submission arrived from.
    TOR = "tor"
    PROXY = "proxy"
    RESIDENTIAL_PROXY = "residential_proxy"
    RESIDENTIAL_PROXY_LOW_CONFIDENCE = "residential_proxy_low_confidence"
    RESIDENTIAL_PROXY_MEDIUM_CONFIDENCE = "residential_proxy_medium_confidence"
    RESIDENTIAL_PROXY_HIGH_CONFIDENCE = "residential_proxy_high_confidence"
    VPN_PUBLIC = "vpn_public"
    VPN_TIMEZONE = "vpn_timezone"
    VPN_RELAY = "vpn_relay"
    VPN_MOBILE = "vpn_mobile"
    VPN_OS_MISMATCH = "vpn_os_mismatch"
    VPN_LOW_CONFIDENCE = "vpn_low_confidence"
    VPN_MEDIUM_CONFIDENCE = "vpn_medium_confidence"
    VPN_HIGH_CONFIDENCE = "vpn_high_confidence"
    IP_BLOCKLIST_EMAIL_SPAM = "ip_blocklist_email_spam"
    IP_BLOCKLIST_ATTACK_SOURCE = "ip_blocklist_attack_source"
    IP_ABUSER = "ip_abuser"
    DATACENTER_IP = "datacenter_ip"
    BOGON_IP = "bogon_ip"
    ANYCAST_IP = "anycast_ip"

    # Detectors only a browser can produce.
    INCOGNITO = "incognito"
    BAD_BOT = "bad_bot"
    AUTOMATION = "automation"
    FETCH_METADATA_MISSING = "fetch_metadata_missing"
    WEB_TICKET_MISSING = "web_ticket_missing"
    WEB_TICKET_INVALID = "web_ticket_invalid"
    ANTIDETECT_BROWSER = "antidetect_browser"
    VIRTUAL_MACHINE = "virtual_machine"
    FINGERPRINT_SUPPRESSED = "fingerprint_suppressed"
    PRIVACY_SETTINGS = "privacy_settings"
    EMBEDDED_WEB_VIEW = "embedded_web_view"
    REMOTE_CONTROL = "remote_control"

    # Detectors only a native application can produce.
    EMULATOR = "emulator"
    ROOT_APPS = "root_apps"
    APP_CLONER = "app_cloner"
    JAILBREAK = "jailbreak"
    SIMULATOR = "simulator"
    FRIDA = "frida"
    MITM_ATTACK = "mitm_attack"
    ACTIVE_CALL = "active_call"
    ATTESTATION_MISSING = "attestation_missing"
    ATTESTATION_DOWNGRADE = "attestation_downgrade"
    REPEATED_REINSTALL = "repeated_reinstall"
    DEVICE_ACTIVITY_HIGH = "device_activity_high"
    DEVICE_ACTIVITY_VERY_HIGH = "device_activity_very_high"
    PLAY_DEVICE_INTEGRITY_FAILED = "play_device_integrity_failed"
    PLAY_APP_UNRECOGNIZED = "play_app_unrecognized"
    ATTESTATION_FAILED = "attestation_failed"
    REPORT_INCOMPLETE = "report_incomplete"
    PROBE_ERRORS = "probe_errors"
    CUSTOM_ROOT_CA = "custom_root_ca"
    SECONDARY_USER_PROFILE = "secondary_user_profile"

    # Signal groups whose name is not also a detector's.
    DATACENTER_PROXY = "datacenter_proxy"
    VPN = "vpn"
    IP_BLOCKLIST = "ip_blocklist"
    IP_REPUTATION = "ip_reputation"
    NETWORK_ANOMALY = "network_anomaly"
    LOCATION_SPOOFING = "location_spoofing"
    IOS_SIMULATOR = "ios_simulator"
    ANDROID_EMULATOR = "android_emulator"
    JAILBROKEN_DEVICE = "jailbroken_device"
    ROOTED_DEVICE = "rooted_device"
    CLONED_APP = "cloned_app"
    FRIDA_DETECTED = "frida_detected"
    BROWSER_TAMPERING = "browser_tampering"
    BOT = "bot"
    INCOGNITO_MODE = "incognito_mode"

    ALL = [
      HIGH_ACTIVITY, TAMPERING, DEVICE_FARM, DEVELOPER_TOOLS, GEO_MISMATCH, DEVICE_INCONSISTENT,
      TOR, PROXY, RESIDENTIAL_PROXY, RESIDENTIAL_PROXY_LOW_CONFIDENCE,
      RESIDENTIAL_PROXY_MEDIUM_CONFIDENCE, RESIDENTIAL_PROXY_HIGH_CONFIDENCE, VPN_PUBLIC,
      VPN_TIMEZONE, VPN_RELAY, VPN_MOBILE, VPN_OS_MISMATCH, VPN_LOW_CONFIDENCE,
      VPN_MEDIUM_CONFIDENCE, VPN_HIGH_CONFIDENCE, IP_BLOCKLIST_EMAIL_SPAM,
      IP_BLOCKLIST_ATTACK_SOURCE, IP_ABUSER, DATACENTER_IP, BOGON_IP, ANYCAST_IP, INCOGNITO,
      BAD_BOT, AUTOMATION, FETCH_METADATA_MISSING, WEB_TICKET_MISSING, WEB_TICKET_INVALID,
      ANTIDETECT_BROWSER, VIRTUAL_MACHINE, FINGERPRINT_SUPPRESSED, PRIVACY_SETTINGS,
      EMBEDDED_WEB_VIEW, REMOTE_CONTROL, EMULATOR, ROOT_APPS, APP_CLONER, JAILBREAK, SIMULATOR,
      FRIDA, MITM_ATTACK, ACTIVE_CALL, ATTESTATION_MISSING, ATTESTATION_DOWNGRADE,
      REPEATED_REINSTALL, DEVICE_ACTIVITY_HIGH, DEVICE_ACTIVITY_VERY_HIGH,
      PLAY_DEVICE_INTEGRITY_FAILED, PLAY_APP_UNRECOGNIZED, ATTESTATION_FAILED, REPORT_INCOMPLETE,
      PROBE_ERRORS, CUSTOM_ROOT_CA, SECONDARY_USER_PROFILE, DATACENTER_PROXY, VPN, IP_BLOCKLIST,
      IP_REPUTATION, NETWORK_ANOMALY, LOCATION_SPOOFING, IOS_SIMULATOR, ANDROID_EMULATOR,
      JAILBROKEN_DEVICE, ROOTED_DEVICE, CLONED_APP, FRIDA_DETECTED, BROWSER_TAMPERING, BOT,
      INCOGNITO_MODE
    ].freeze
  end

  # An event's +suspect_level+, and the +level+ of identification webhooks:
  # the score, banded.
  module SuspectLevel
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"

    ALL = [LOW, MEDIUM, HIGH].freeze
  end

  # How sure a detection is: {EventTrigger#confidence}.
  module Confidence
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"

    ALL = [LOW, MEDIUM, HIGH].freeze
  end

  # The server's verdict on a native event's hardware evidence: the archived
  # document's +attestation.state+.
  module AttestationState
    ATTESTED = "attested"
    NOT_ATTESTED = "not_attested"
    FAILED = "failed"

    ALL = [ATTESTED, NOT_ATTESTED, FAILED].freeze
  end

  # The detail behind {AttestationState}: the archived document's
  # +attestation.status+.
  module AttestationStatus
    VERIFIED = "verified"
    INDETERMINATE = "indeterminate"
    INVALID = "invalid"
    ABSENT = "absent"
    UNCONFIGURED = "unconfigured"

    ALL = [VERIFIED, INDETERMINATE, INVALID, ABSENT, UNCONFIGURED].freeze
  end

  # Why a native app sent no attestation: the archived document's
  # +attestation.attest_skipped+. Diagnostic only; it never lowers the score.
  module AttestSkippedReason
    # The challenge offered no attestation: on iOS the SDK key has no Apple app
    # ID for App Attest, on Android the app's transport returned no challenge
    # offer.
    NOT_OFFERED = "not_offered"
    # The device cannot make an attested key: App Attest is not supported on
    # the iOS device, or Android is older than 7.0 (API 24).
    UNSUPPORTED = "unsupported"
    # No usable challenge ticket: the challenge request failed, or on Android
    # the ticket it returned was malformed.
    CHALLENGE_UNAVAILABLE = "challenge_unavailable"
    # The platform key store failed to create, attest or sign with the key, or
    # on Android the stored key record could not be read.
    KEY_ERROR = "key_error"
    # Attestation did not finish in time: a key store call ran past its budget,
    # or another identification held the attestation step too long.
    TIMEOUT = "timeout"
    # The server rejected a new key from this install (on iOS, also when it
    # asked for a replacement), and the SDK is waiting out a backoff before it
    # registers another.
    BACKOFF = "backoff"
    # The report has no usable install ID, or on iOS the stored key record could
    # not be read or saved.
    INSTALL_UNAVAILABLE = "install_unavailable"

    ALL = [
      NOT_OFFERED, UNSUPPORTED, CHALLENGE_UNAVAILABLE, KEY_ERROR, TIMEOUT, BACKOFF,
      INSTALL_UNAVAILABLE
    ].freeze
  end

  # Why +fingerly.events.verify+ refused an event: {EventVerification#reason}.
  # +OK+ is the +""+ of an event that passed; the failures follow in the order
  # the checks run.
  module VerifyReason
    OK = ""
    NOT_FOUND = "not_found"
    TOO_OLD = "too_old"
    TAG_MISMATCH = "tag_mismatch"
    UNIDENTIFIABLE = "unidentifiable"
    UNSCORED = "unscored"
    ALREADY_CONSUMED = "already_consumed"

    ALL = [OK, NOT_FOUND, TOO_OLD, TAG_MISMATCH, UNIDENTIFIABLE, UNSCORED, ALREADY_CONSUMED].freeze
  end

  # A webhook delivery's {WebhookEvent#type}. +WEBHOOK_TEST+ is sent to one
  # endpoint on request and cannot be subscribed to.
  module WebhookEventType
    IDENTIFICATION_COMPLETED = "identification.completed"
    IDENTIFICATION_REFUSED = "identification.refused"
    VISITOR_SUSPECT = "visitor.suspect"
    BILLING_STATUS_CHANGED = "billing.status_changed"
    USAGE_DAILY_SETTLED = "usage.daily_settled"
    WEBHOOK_TEST = "webhook.test"

    ALL = [
      IDENTIFICATION_COMPLETED, IDENTIFICATION_REFUSED, VISITOR_SUSPECT, BILLING_STATUS_CHANGED,
      USAGE_DAILY_SETTLED, WEBHOOK_TEST
    ].freeze
  end

  # A webhook delivery's {WebhookEvent#environment}.
  module WebhookEnvironment
    LIVE = "live"
    TEST = "test"

    ALL = [LIVE, TEST].freeze
  end

  # An event's +state+: enriched, or unavailable when the network lookup
  # could not run. +PENDING+ is accepted and not yet written; an event read
  # answers it as a pending error rather than as an event.
  module EventState
    PENDING = "pending"
    ENRICHED = "enriched"
    UNAVAILABLE = "unavailable"

    ALL = [PENDING, ENRICHED, UNAVAILABLE].freeze
  end

  # The environment an event was recorded in: {Event}'s +environment+.
  module Environment
    PRODUCTION = "production"
    STAGING = "staging"
    DEVELOPMENT = "development"

    ALL = [PRODUCTION, STAGING, DEVELOPMENT].freeze
  end

  # The scoring profile an event was scored under: {Event}'s +platform+.
  # +sdk_platform+ is what the SDK called itself and is not limited to these.
  module Platform
    WEB = "web"
    ANDROID = "android"
    IOS = "ios"

    ALL = [WEB, ANDROID, IOS].freeze
  end

  # The anonymity network an event's address belongs to: {Event}'s
  # +anonymity_network+, nil on an ordinary connection.
  module AnonymityNetwork
    TOR = "tor"
    RELAY = "relay"
    VPN = "vpn"
    PROXY = "proxy"
    HOSTING = "hosting"

    ALL = [TOR, RELAY, VPN, PROXY, HOSTING].freeze
  end

  # What the fingerprint was taken on: {Event}'s +device_kind+.
  module DeviceKind
    DESKTOP = "desktop"
    MOBILE = "mobile"
    TABLET = "tablet"
    SERVER = "server"

    ALL = [DESKTOP, MOBILE, TABLET, SERVER].freeze
  end

  # What is behind a submission: {Event}'s +visitor_kind+.
  module VisitorKind
    HUMAN = "human"
    AI_BOT = "ai_bot"
    AUTOMATION = "automation"
    SEARCH_CRAWLER = "search_crawler"

    ALL = [HUMAN, AI_BOT, AUTOMATION, SEARCH_CRAWLER].freeze
  end

  # What an AI agent's operator says its traffic is for: {AiAgent}'s
  # +purpose+. The API can add values, so keep an +else+ branch.
  module AiPurpose
    # Collecting content to train models.
    TRAINING = "training"
    # Indexing for an AI answer or search product.
    SEARCH = "search"
    # Reading a page a person asked an assistant to read.
    USER_FETCH = "user_fetch"
    # Driving a browser on a person's behalf.
    AGENT = "agent"

    ALL = [TRAINING, SEARCH, USER_FETCH, AGENT].freeze
  end

  # Where an AI agent runs: {AiAgent}'s +runtime+. The API can add values, so
  # keep an +else+ branch.
  module AiRuntime
    # The operator's own infrastructure.
    PROVIDER_CLOUD = "provider_cloud"
    # A third party's cloud browser.
    HOSTED_BROWSER = "hosted_browser"
    # A person's own browser.
    USER_DEVICE = "user_device"

    ALL = [PROVIDER_CLOUD, HOSTED_BROWSER, USER_DEVICE].freeze
  end

  # How an AI agent's claimed identity was checked: {AiVerification}'s
  # +method+. The API can add values, so keep an +else+ branch.
  module AiVerificationMethod
    # A signed request.
    SIGNATURE = "signature"
    # The operator's published address ranges.
    IP_LIST = "ip_list"
    # A reverse lookup confirmed forward.
    REVERSE_DNS = "reverse_dns"
    # No check was made.
    NONE = "none"

    ALL = [SIGNATURE, IP_LIST, REVERSE_DNS, NONE].freeze
  end

  # What checking an AI agent's identity found: {AiVerification}'s +result+.
  # The API can add values, so keep an +else+ branch.
  module AiVerificationResult
    # The claim held.
    PASS = "pass"
    # The claim was checked and did not hold.
    FAIL = "fail"
    # No check was made.
    NOT_ATTEMPTED = "not_attempted"

    ALL = [PASS, FAIL, NOT_ATTEMPTED].freeze
  end
end
