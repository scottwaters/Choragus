import Foundation

public enum L10n {

    // MARK: - General
    public static var settings: String { tr("settings") }
    public static var done: String { tr("done") }
    public static var dismiss: String { tr("dismiss") }
    public static var cancel: String { tr("cancel") }
    public static var browse: String { tr("browse") }
    public static var rooms: String { tr("rooms") }
    public static var all: String { tr("all") }

    // MARK: - Content View
    public static var usingCachedData: String { tr("usingCachedData") }
    public static var networkUnstableAdvisory: String { tr("networkUnstableAdvisory") }
    public static var refreshing: String { tr("refreshing") }
    public static var searchingForSpeakers: String { tr("searchingForSpeakers") }
    public static var loadingCachedSpeakers: String { tr("loadingCachedSpeakers") }
    public static var selectARoom: String { tr("selectARoom") }
    public static var browseMusicLibrary: String { tr("browseMusicLibrary") }
    public static var showPlayQueue: String { tr("showPlayQueue") }
    public static var manageAlarms: String { tr("manageAlarms") }
    public static var muteAllSpeakers: String { tr("muteAllSpeakers") }
    public static var unmuteAllSpeakers: String { tr("unmuteAllSpeakers") }
    public static var muteOrUnmuteAll: String { tr("muteOrUnmuteAll") }
    public static var rescanNetwork: String { tr("rescanNetwork") }
    public static var appSettings: String { tr("appSettings") }

    // MARK: - Now Playing
    public static var noTrack: String { tr("noTrack") }
    public static var nothingPlaying: String { tr("nothingPlaying") }
    public static var playingFrom: String { tr("playingFrom") }
    public static var errorTracksSkippingEarly: String { tr("errorTracksSkippingEarly") }
    public static var live: String { tr("live") }
    public static var addToChoragusQueue: String { tr("addToChoragusQueue") }
    public static var jumpToLetter: String { tr("jumpToLetter") }
    public static var pasteSunoLink: String { tr("pasteSunoLink") }
    public static func trackPhoto(_ title: String) -> String {
        String(format: tr("trackPhoto"), title)
    }
    public static func trackAppleMusicImage(_ title: String) -> String {
        String(format: tr("trackAppleMusicImage"), title)
    }
    public static var group: String { tr("group") }
    public static var sleep: String { tr("sleep") }
    public static var eq: String { tr("eq") }
    public static var shuffle: String { tr("shuffle") }
    public static var repeat_: String { tr("repeat_") }
    public static var refreshArtwork: String { tr("refreshArtwork") }
    public static var clearArtwork: String { tr("clearArtwork") }
    public static var copyTrackInfo: String { tr("copyTrackInfo") }
    public static var copied: String { tr("copied") }
    public static var speakerVolumes: String { tr("speakerVolumes") }

    // MARK: - Browse
    public static var browseHome: String { tr("browseHome") }
    public static var back: String { tr("back") }
    public static var localSearch: String { tr("localSearch") }
    public static var discoveringContent: String { tr("discoveringContent") }
    public static var libraryAndFavorites: String { tr("libraryAndFavorites") }
    public static var loading: String { tr("loading") }
    public static var empty: String { tr("empty") }
    public static var requiresSonosApp: String { tr("requiresSonosApp") }
    public static var loadMore: String { tr("loadMore") }
    public static var of: String { tr("of") }
    public static var playNow: String { tr("playNow") }
    public static var playNext: String { tr("playNext") }
    public static var addToQueue: String { tr("addToQueue") }
    public static var playTopSongs: String { tr("playTopSongs") }
    public static var queueTopSongsNext: String { tr("queueTopSongsNext") }
    public static var addTopSongsToQueue: String { tr("addTopSongsToQueue") }
    public static var couldNotPlay: String { tr("couldNotPlay") }
    public static var sunoLinkUnreadable: String { tr("sunoLinkUnreadable") }
    public static var playlistPrompt01: String { tr("playlistPrompt01") }
    public static var playlistPrompt02: String { tr("playlistPrompt02") }
    public static var playlistPrompt03: String { tr("playlistPrompt03") }
    public static var playlistPrompt04: String { tr("playlistPrompt04") }
    public static var playlistPrompt05: String { tr("playlistPrompt05") }
    public static var playlistPrompt06: String { tr("playlistPrompt06") }
    public static var playlistPrompt07: String { tr("playlistPrompt07") }
    public static var playlistPrompt08: String { tr("playlistPrompt08") }
    public static var playlistPrompt09: String { tr("playlistPrompt09") }
    public static var playlistPrompt10: String { tr("playlistPrompt10") }
    public static var playlistPrompt11: String { tr("playlistPrompt11") }
    public static var playlistPrompt12: String { tr("playlistPrompt12") }
    public static func playlistBuilderExampleFormat(_ prompt: String) -> String { String(format: tr("playlistBuilderExampleFormat"), prompt) }
    public static var playlistBuilderSamplesLink: String { tr("playlistBuilderSamplesLink") }
    public static var playlistBuilderChoragusFolder: String { tr("playlistBuilderChoragusFolder") }
    /// Sample prompts for Build Playlist with AI, one shown at random each time the window opens.
    public static var playlistSamplePrompts: [String] {
        [playlistPrompt01, playlistPrompt02, playlistPrompt03, playlistPrompt04, playlistPrompt05, playlistPrompt06, playlistPrompt07, playlistPrompt08, playlistPrompt09, playlistPrompt10, playlistPrompt11, playlistPrompt12]
    }
    public static var mayRequireSignIn: String { tr("mayRequireSignIn") }
    public static var error_: String { tr("error_") }

    // MARK: - Queue
    public static var queue: String { tr("queue") }
    public static var tracks: String { tr("tracks") }
    public static var clearQueue: String { tr("clearQueue") }
    public static var queueIsEmpty: String { tr("queueIsEmpty") }
    public static var play: String { tr("play") }
    public static var removeFromQueue: String { tr("removeFromQueue") }

    // MARK: - Alarms
    public static var alarms: String { tr("alarms") }
    public static var noAlarmsSet: String { tr("noAlarmsSet") }
    public static var delete: String { tr("delete") }

    // MARK: - Group Editor
    public static var groupSpeakers: String { tr("groupSpeakers") }
    public static var tapToAddOrRemove: String { tr("tapToAddOrRemove") }
    public static var coordinator: String { tr("coordinator") }
    public static var inGroup: String { tr("inGroup") }
    public static var groupAll: String { tr("groupAll") }
    public static var ungroupAll: String { tr("ungroupAll") }

    // MARK: - Sleep Timer
    public static var sleepTimer: String { tr("sleepTimer") }
    public static var timeRemaining: String { tr("timeRemaining") }
    public static var cancelTimer: String { tr("cancelTimer") }
    public static var min15: String { tr("min15") }
    public static var min30: String { tr("min30") }
    public static var min45: String { tr("min45") }
    public static var hour1: String { tr("hour1") }
    public static var hours2: String { tr("hours2") }

    // MARK: - EQ
    public static var bass: String { tr("bass") }
    public static var treble: String { tr("treble") }
    public static var loudness: String { tr("loudness") }

    // MARK: - Settings
    public static var appearance: String { tr("appearance") }
    public static var theme: String { tr("theme") }
    public static var colors: String { tr("colors") }
    public static var accent: String { tr("accent") }
    public static var playing: String { tr("playing") }
    public static var inactive: String { tr("inactive") }
    public static var aboutAppearance: String { tr("aboutAppearance") }
    public static var appearanceInfo: String { tr("appearanceInfo") }
    public static var network: String { tr("network") }
    public static var updates: String { tr("updates") }
    public static var activeSubscriptions: String { tr("activeSubscriptions") }
    public static var startup: String { tr("startup") }
    public static var aboutNetwork: String { tr("aboutNetwork") }
    public static var networkInfo: String { tr("networkInfo") }
    public static var cache: String { tr("cache") }
    public static var cachedData: String { tr("cachedData") }
    public static var liveData: String { tr("liveData") }
    public static var artwork: String { tr("artwork") }
    public static var images: String { tr("images") }
    public static var maxSize: String { tr("maxSize") }
    public static var maxAge: String { tr("maxAge") }
    public static var days7: String { tr("days7") }
    public static var days30: String { tr("days30") }
    public static var days90: String { tr("days90") }
    public static var year1: String { tr("year1") }
    public static var never: String { tr("never") }
    public static var clearSpeakerCache: String { tr("clearSpeakerCache") }
    public static var clearArtworkCache: String { tr("clearArtworkCache") }
    public static var aboutCache: String { tr("aboutCache") }
    public static var cacheInfo: String { tr("cacheInfo") }
    public static var language: String { tr("language") }
    public static var translationHelpNote: String { tr("translationHelpNote") }

    // MARK: - Colors
    public static var system: String { tr("system") }
    public static var customColor: String { tr("customColor") }

    // MARK: - Source Labels
    public static var musicLibrary: String { tr("musicLibrary") }
    public static var radio: String { tr("radio") }
    public static var sonosPlaylist: String { tr("sonosPlaylist") }
    public static var tv: String { tr("tv") }
    public static var lineIn: String { tr("lineIn") }

    // MARK: - Copy Track Info Labels
    public static var sourceLabel: String { tr("sourceLabel") }
    public static var artistLabel: String { tr("artistLabel") }
    public static var albumLabel: String { tr("albumLabel") }
    public static var trackLabel: String { tr("trackLabel") }

    // MARK: - Group Presets
    public static var groupPresets: String { tr("groupPresets") }
    public static var managePresets: String { tr("managePresets") }
    public static var saveFromCurrent: String { tr("saveFromCurrent") }
    public static var presetName: String { tr("presetName") }
    public static var applyPreset: String { tr("applyPreset") }
    public static var deletePreset: String { tr("deletePreset") }
    public static var noPresets: String { tr("noPresets") }

    // MARK: - Play History
    public static var playHistory: String { tr("playHistory") }
    public static var enablePlayHistory: String { tr("enablePlayHistory") }
    public static var clearHistory: String { tr("clearHistory") }

    // MARK: - Appearance Modes
    public static var systemMode: String { tr("systemMode") }
    public static var lightMode: String { tr("lightMode") }
    public static var darkMode: String { tr("darkMode") }

    // MARK: - Communication Modes
    public static var eventDriven: String { tr("eventDriven") }
    public static var legacyPolling: String { tr("legacyPolling") }

    // MARK: - Discovery
    public static var discovery: String { tr("discovery") }
    public static var autoDiscovery: String { tr("autoDiscovery") }
    public static var bonjourDiscovery: String { tr("bonjourDiscovery") }
    public static var legacyMulticast: String { tr("legacyMulticast") }
    public static var discoveryAutoHint: String { tr("discoveryAutoHint") }

    // MARK: - iTunes Rate Limiter
    public static var appleMusicSearch: String { tr("appleMusicSearch") }
    public static var appleMusicSearchReady: String { tr("appleMusicSearchReady") }
    public static var appleMusicSearchUnavailable: String { tr("appleMusicSearchUnavailable") }
    public static var appleMusicSearchCoolingDown: String { tr("appleMusicSearchCoolingDown") }
    public static func appleMusicResumesAt(_ time: String) -> String {
        String(format: tr("appleMusicResumesAt"), time)
    }
    public static func iTunesQueriesInWindow(_ used: Int, _ cap: Int) -> String {
        String(format: tr("iTunesQueriesInWindow"), used, cap)
    }

    // MARK: - Startup Modes
    public static var quickStart: String { tr("quickStart") }
    public static var classic: String { tr("classic") }

    // MARK: - Menus (added v3.5)
    public static var aboutChoragus: String { tr("aboutChoragus") }
    public static var checkForUpdates: String { tr("checkForUpdates") }
    public static var choragusHelp: String { tr("choragusHelp") }
    public static var viewSourceOnGitHub: String { tr("viewSourceOnGitHub") }
    public static var reportAnIssue: String { tr("reportAnIssue") }
    public static var toggleBrowseLibrary: String { tr("toggleBrowseLibrary") }
    public static var togglePlayQueue: String { tr("togglePlayQueue") }
    public static var listeningStats: String { tr("listeningStats") }
    public static var playPause: String { tr("playPause") }
    public static var nextTrack: String { tr("nextTrack") }
    public static var previousTrack: String { tr("previousTrack") }
    public static var muteUnmute: String { tr("muteUnmute") }
    public static var controls: String { tr("controls") }

    // MARK: - Update Checker (added v3.5)
    public static var updateAvailableTitle: String { tr("updateAvailableTitle") }
    public static var viewOnGitHub: String { tr("viewOnGitHub") }
    public static var later: String { tr("later") }
    public static var upToDateTitle: String { tr("upToDateTitle") }
    public static var updateCheckFailedTitle: String { tr("updateCheckFailedTitle") }
    public static var releaseNotesLabel: String { tr("releaseNotesLabel") }
    public static var ok: String { tr("ok") }

    /// "You are running %@. The latest release is %@."
    public static func updateAvailableBody(current: String, latest: String) -> String {
        String(format: tr("updateAvailableBody"), current, latest)
    }

    /// "You are running the latest release (%@)."
    public static func upToDateBody(version: String) -> String {
        String(format: tr("upToDateBody"), version)
    }

    /// "GitHub returned HTTP %d."
    public static func updateCheckHTTPError(status: Int) -> String {
        String(format: tr("updateCheckHTTPError"), status)
    }

    // MARK: - First-Run Welcome (added v3.5)
    public static var welcomeTitle: String { tr("welcomeTitle") }
    public static var welcomeBody: String { tr("welcomeBody") }
    public static var openSettings: String { tr("openSettings") }

    // MARK: - Help Topics (added v3.5)
    public static var helpGettingStarted: String { tr("helpGettingStarted") }
    public static var helpPlayback: String { tr("helpPlayback") }
    public static var helpGrouping: String { tr("helpGrouping") }
    public static var helpBrowsingMusic: String { tr("helpBrowsingMusic") }
    public static var helpS1AndS2: String { tr("helpS1AndS2") }
    public static var helpPreferences: String { tr("helpPreferences") }
    public static var helpKeyboardShortcuts: String { tr("helpKeyboardShortcuts") }
    public static var helpAboutAndSupport: String { tr("helpAboutAndSupport") }
    public static var helpAppleShortcuts: String { tr("helpAppleShortcuts") }
    public static var helpAppleShortcutsHeading: String { tr("helpAppleShortcutsHeading") }
    public static var helpAppleShortcutsBody: String { tr("helpAppleShortcutsBody") }
    public static var helpAlarmsHeading: String { tr("helpAlarmsHeading") }
    public static var helpGroupListening: String { tr("helpGroupListening") }
    public static var helpGroupMusic: String { tr("helpGroupMusic") }
    public static var helpGroupAutomation: String { tr("helpGroupAutomation") }
    public static var helpGroupSystem: String { tr("helpGroupSystem") }
    public static var helpGroupAI: String { tr("helpGroupAI") }
    public static var helpQueueHeaderBody: String { tr("helpQueueHeaderBody") }
    public static var helpArtworkBody: String { tr("helpArtworkBody") }
    public static var helpBulletGroupAll: String { tr("helpBulletGroupAll") }
    public static var helpBulletRescan: String { tr("helpBulletRescan") }
    public static var helpBulletChoragusSources: String { tr("helpBulletChoragusSources") }
    public static var helpSortBody: String { tr("helpSortBody") }
    public static var helpBulletDisplayTab: String { tr("helpBulletDisplayTab") }
    public static var helpBulletHistorySettings: String { tr("helpBulletHistorySettings") }
    public static var helpBulletPlaybackSettings: String { tr("helpBulletPlaybackSettings") }
    public static var helpBulletAITab: String { tr("helpBulletAITab") }
    public static var helpBulletSystemTab: String { tr("helpBulletSystemTab") }
    public static var helpDiagnosticsMCPBody: String { tr("helpDiagnosticsMCPBody") }
    public static var helpVisIntroBody: String { tr("helpVisIntroBody") }
    public static var helpVisWallBody: String { tr("helpVisWallBody") }
    public static var helpVisLightingBody: String { tr("helpVisLightingBody") }
    public static var helpVisSettingsBody: String { tr("helpVisSettingsBody") }
    public static var helpAgentWhatHeading: String { tr("helpAgentWhatHeading") }
    public static var helpAgentBulletPlay: String { tr("helpAgentBulletPlay") }
    public static var helpAgentBulletFind: String { tr("helpAgentBulletFind") }
    public static var helpAgentBulletQueue: String { tr("helpAgentBulletQueue") }
    public static var helpAgentBulletPlaylists: String { tr("helpAgentBulletPlaylists") }
    public static var helpAgentBulletBuilder: String { tr("helpAgentBulletBuilder") }
    public static var helpAgentBulletHouse: String { tr("helpAgentBulletHouse") }
    public static var helpAgentBulletHistory: String { tr("helpAgentBulletHistory") }
    public static var helpAgentBulletAlarms: String { tr("helpAgentBulletAlarms") }
    public static var helpAgentLimitsHeading: String { tr("helpAgentLimitsHeading") }
    public static var helpAgentLimitsBody: String { tr("helpAgentLimitsBody") }
    public static var helpMCPSeeAgentAccess: String { tr("helpMCPSeeAgentAccess") }
    public static var helpAlarmsBody: String { tr("helpAlarmsBody") }
    public static var helpAlarmsEditorBody: String { tr("helpAlarmsEditorBody") }
    public static var helpAlarmsNotesBody: String { tr("helpAlarmsNotesBody") }
    public static var helpAppleShortcutsActionsHeading: String { tr("helpAppleShortcutsActionsHeading") }
    public static var helpShortcutActionPlay: String { tr("helpShortcutActionPlay") }
    public static var helpShortcutActionSkip: String { tr("helpShortcutActionSkip") }
    public static var helpShortcutActionVolume: String { tr("helpShortcutActionVolume") }
    public static var helpShortcutActionPreset: String { tr("helpShortcutActionPreset") }
    public static var helpShortcutActionInput: String { tr("helpShortcutActionInput") }
    public static var helpAppleShortcutsScheduleHeading: String { tr("helpAppleShortcutsScheduleHeading") }
    public static var helpAppleShortcutsScheduleBody: String { tr("helpAppleShortcutsScheduleBody") }

    // MARK: - Help body strings
    public static var diagNetworkSettleNote: String { tr("diagNetworkSettleNote") }
    public static var helpWelcome: String { tr("helpWelcome") }
    public static var helpQueueLibrarySourcesBody: String { tr("helpQueueLibrarySourcesBody") }
    public static var helpQueueLibraryOrganiseBody: String { tr("helpQueueLibraryOrganiseBody") }
    public static var helpQueueLibraryExportBody: String { tr("helpQueueLibraryExportBody") }
    public static var helpPresetsHeading: String { tr("helpPresetsHeading") }
    public static var helpPresetsBody: String { tr("helpPresetsBody") }
    public static var helpPlaylistManagementBody: String { tr("helpPlaylistManagementBody") }
    public static var helpKaraokeSettingsBody: String { tr("helpKaraokeSettingsBody") }
    public static var helpNetworkTabHeading: String { tr("helpNetworkTabHeading") }
    public static var helpNetworkTabBody: String { tr("helpNetworkTabBody") }
    public static var helpSunoBody: String { tr("helpSunoBody") }
    public static var helpSupportHeading: String { tr("helpSupportHeading") }
    public static var helpSupportBody: String { tr("helpSupportBody") }
    public static var helpVisualisationsHeading: String { tr("helpVisualisationsHeading") }
    public static var helpVisualisationsBody: String { tr("helpVisualisationsBody") }
    public static var helpCrossfadeSleepHeading: String { tr("helpCrossfadeSleepHeading") }
    public static var helpCrossfadeSleepBody: String { tr("helpCrossfadeSleepBody") }
    public static var helpAudioFormatBadgesBody: String { tr("helpAudioFormatBadgesBody") }
    public static var helpSurroundModeBody: String { tr("helpSurroundModeBody") }
    public static var helpIgnoreTVBody: String { tr("helpIgnoreTVBody") }
    public static var helpQueueLibraryHeading: String { tr("helpQueueLibraryHeading") }
    public static var helpQueueLibraryBody: String { tr("helpQueueLibraryBody") }
    public static var helpSaveToPlaylistBody: String { tr("helpSaveToPlaylistBody") }
    public static var helpQueueSourceBody: String { tr("helpQueueSourceBody") }
    public static var helpMoreServicesHeading: String { tr("helpMoreServicesHeading") }
    public static var helpMoreServicesBody: String { tr("helpMoreServicesBody") }
    public static var helpHistoryActionsBody: String { tr("helpHistoryActionsBody") }
    public static var helpWindowLifecycleBody: String { tr("helpWindowLifecycleBody") }
    public static var helpMediaKeysHeading: String { tr("helpMediaKeysHeading") }
    public static var helpMediaKeysBody: String { tr("helpMediaKeysBody") }
    public static var helpLockedScreenBody: String { tr("helpLockedScreenBody") }
    public static var helpHomeTheaterTogglesHeading: String { tr("helpHomeTheaterTogglesHeading") }
    public static var helpHomeTheaterTogglesBody: String { tr("helpHomeTheaterTogglesBody") }
    public static var helpGroupingGesturesHeading: String { tr("helpGroupingGesturesHeading") }
    public static var helpGroupingGesturesBody: String { tr("helpGroupingGesturesBody") }
    public static var helpVolumeSyncBody: String { tr("helpVolumeSyncBody") }
    public static var helpLibrarySharesHeading: String { tr("helpLibrarySharesHeading") }
    public static var helpLibrarySharesBody: String { tr("helpLibrarySharesBody") }
    public static var helpRenameFavoriteBody: String { tr("helpRenameFavoriteBody") }
    public static var helpQueueFollowBody: String { tr("helpQueueFollowBody") }
    public static var helpFastScrollBody: String { tr("helpFastScrollBody") }
    public static var helpSpeakersTabBody: String { tr("helpSpeakersTabBody") }
    public static var helpWelcomeBody: String { tr("helpWelcomeBody") }
    public static var helpFirstLaunch: String { tr("helpFirstLaunch") }
    public static var helpBulletDiscovery: String { tr("helpBulletDiscovery") }
    public static var helpBulletSidebarRooms: String { tr("helpBulletSidebarRooms") }
    public static var helpBulletSelectRoom: String { tr("helpBulletSelectRoom") }
    public static var helpBulletToolbar: String { tr("helpBulletToolbar") }
    public static var helpNoSpeakersFound: String { tr("helpNoSpeakersFound") }
    public static var helpNoSpeakersFoundBody: String { tr("helpNoSpeakersFoundBody") }

    public static var helpControllingPlayback: String { tr("helpControllingPlayback") }
    public static var helpControllingPlaybackBody: String { tr("helpControllingPlaybackBody") }
    public static var helpBulletSpaceBar: String { tr("helpBulletSpaceBar") }
    public static var helpBulletControlsMenu: String { tr("helpBulletControlsMenu") }
    public static var helpBulletRightClickRoom: String { tr("helpBulletRightClickRoom") }
    public static var helpBulletStarTrack: String { tr("helpBulletStarTrack") }
    public static var helpVolumeHeading: String { tr("helpVolumeHeading") }
    public static var helpVolumeBody: String { tr("helpVolumeBody") }
    public static var helpTransportState: String { tr("helpTransportState") }
    public static var helpTransportStateBody: String { tr("helpTransportStateBody") }

    public static var helpGroupingSpeakers: String { tr("helpGroupingSpeakers") }
    public static var helpGroupingSpeakersBody: String { tr("helpGroupingSpeakersBody") }
    public static var helpBulletEditGroup: String { tr("helpBulletEditGroup") }
    public static var helpBulletUngroupAll: String { tr("helpBulletUngroupAll") }
    public static var helpBulletPreset: String { tr("helpBulletPreset") }
    public static var helpHomeTheaterSets: String { tr("helpHomeTheaterSets") }
    public static var helpHomeTheaterSetsBody: String { tr("helpHomeTheaterSetsBody") }

    public static var helpBrowsingMusicSection: String { tr("helpBrowsingMusicSection") }
    public static var helpBrowsingMusicBody: String { tr("helpBrowsingMusicBody") }
    public static var helpBulletFavorites: String { tr("helpBulletFavorites") }
    public static var helpBulletLibrary: String { tr("helpBulletLibrary") }
    public static var helpBulletServicesSection: String { tr("helpBulletServicesSection") }
    public static var helpBulletSearch: String { tr("helpBulletSearch") }
    public static var helpAddingToQueue: String { tr("helpAddingToQueue") }
    public static var helpAddingToQueueBody: String { tr("helpAddingToQueueBody") }

    public static var helpSystemsSection: String { tr("helpSystemsSection") }
    public static var helpSystemsBody: String { tr("helpSystemsBody") }
    public static var helpBulletBothSystems: String { tr("helpBulletBothSystems") }
    public static var helpBulletOneSystem: String { tr("helpBulletOneSystem") }
    public static var helpBulletUPnPIdent: String { tr("helpBulletUPnPIdent") }
    public static var helpIndependence: String { tr("helpIndependence") }
    public static var helpIndependenceBody: String { tr("helpIndependenceBody") }

    public static var helpPreferencesSection: String { tr("helpPreferencesSection") }
    public static var helpPreferencesBody: String { tr("helpPreferencesBody") }
    public static var helpBulletAppearance: String { tr("helpBulletAppearance") }
    public static var helpBulletMenuBar: String { tr("helpBulletMenuBar") }
    public static var helpBulletCommunication: String { tr("helpBulletCommunication") }
    public static var helpBulletQuickStart: String { tr("helpBulletQuickStart") }
    public static var helpBulletMusicServices: String { tr("helpBulletMusicServices") }
    public static var helpListeningStatsSection: String { tr("helpListeningStatsSection") }
    public static var helpListeningStatsBody: String { tr("helpListeningStatsBody") }

    public static var helpShortcutsHeading: String { tr("helpShortcutsHeading") }
    public static var helpShortcutGroupPlayback: String { tr("helpShortcutGroupPlayback") }
    public static var helpShortcutGroupView: String { tr("helpShortcutGroupView") }
    public static var helpShortcutGroupApp: String { tr("helpShortcutGroupApp") }
    public static var helpPlayPauseFocus: String { tr("helpPlayPauseFocus") }
    public static var helpEnterFullScreen: String { tr("helpEnterFullScreen") }
    public static var helpShortcutsHelp: String { tr("helpShortcutsHelp") }
    public static var helpHideApp: String { tr("helpHideApp") }
    public static var helpQuitApp: String { tr("helpQuitApp") }

    public static var helpAboutSection: String { tr("helpAboutSection") }
    public static var helpAboutBody1: String { tr("helpAboutBody1") }
    public static var helpAboutBody2: String { tr("helpAboutBody2") }
    public static var helpSourceCodeAndIssues: String { tr("helpSourceCodeAndIssues") }
    public static var helpLicense: String { tr("helpLicense") }
    public static var helpLicenseBody: String { tr("helpLicenseBody") }

    // v4.0 help additions
    public static var helpRebrandHeading: String { tr("helpRebrandHeading") }
    public static var helpRebrandBody: String { tr("helpRebrandBody") }
    public static var helpNowPlayingDetails: String { tr("helpNowPlayingDetails") }
    public static var helpNowPlayingDetailsHeading: String { tr("helpNowPlayingDetailsHeading") }
    public static var helpNowPlayingDetailsBody: String { tr("helpNowPlayingDetailsBody") }
    public static var helpLyricsTabHeading: String { tr("helpLyricsTabHeading") }
    public static var helpLyricsTabBody: String { tr("helpLyricsTabBody") }
    public static var helpBulletLyricsSynced: String { tr("helpBulletLyricsSynced") }
    public static var helpBulletLyricsPlain: String { tr("helpBulletLyricsPlain") }
    public static var helpBulletLyricsOffset: String { tr("helpBulletLyricsOffset") }
    public static var helpKaraokePopoutHeading: String { tr("helpKaraokePopoutHeading") }
    public static var helpKaraokePopoutBody: String { tr("helpKaraokePopoutBody") }
    public static var helpDiagnosticsTopic: String { tr("helpDiagnosticsTopic") }
    public static var helpDiagnosticsHeading: String { tr("helpDiagnosticsHeading") }
    public static var helpDiagnosticsBody: String { tr("helpDiagnosticsBody") }
    public static var helpDiagnosticsOpeningHeading: String { tr("helpDiagnosticsOpeningHeading") }
    public static var helpDiagnosticsOpeningBody: String { tr("helpDiagnosticsOpeningBody") }
    public static var helpDiagnosticsReportingHeading: String { tr("helpDiagnosticsReportingHeading") }
    public static var helpDiagnosticsReportingBody: String { tr("helpDiagnosticsReportingBody") }
    public static var helpDiagnosticsRedactionHeading: String { tr("helpDiagnosticsRedactionHeading") }
    public static var helpDiagnosticsRedactionBody: String { tr("helpDiagnosticsRedactionBody") }
    public static var helpLogMessagesHeading: String { tr("helpLogMessagesHeading") }
    public static var helpLogMessagesBody: String { tr("helpLogMessagesBody") }
    public static var helpLogSpeakerConnection: String { tr("helpLogSpeakerConnection") }
    public static var helpLogPlaybackQueue: String { tr("helpLogPlaybackQueue") }
    public static var helpLogServicesAccounts: String { tr("helpLogServicesAccounts") }
    public static var helpLogDataStorage: String { tr("helpLogDataStorage") }
    public static var helpLogControlsGrouping: String { tr("helpLogControlsGrouping") }
    public static var helpLogArtwork: String { tr("helpLogArtwork") }
    public static var helpDiagnosticsLiveEventsHeading: String { tr("helpDiagnosticsLiveEventsHeading") }
    public static var helpDiagnosticsLiveEventsBody: String { tr("helpDiagnosticsLiveEventsBody") }
    public static var helpDiagnosticsEncryptedHeading: String { tr("helpDiagnosticsEncryptedHeading") }
    public static var helpDiagnosticsEncryptedBody: String { tr("helpDiagnosticsEncryptedBody") }
    public static var helpSoftwareUpdatesHeading: String { tr("helpSoftwareUpdatesHeading") }
    public static var helpSoftwareUpdatesBody: String { tr("helpSoftwareUpdatesBody") }
    public static var helpBetaChannelHeading: String { tr("helpBetaChannelHeading") }
    public static var helpBetaChannelBody: String { tr("helpBetaChannelBody") }
    public static var helpBulletSoftwareUpdates: String { tr("helpBulletSoftwareUpdates") }
    public static var helpAboutTabHeading: String { tr("helpAboutTabHeading") }
    public static var helpAboutTabBody: String { tr("helpAboutTabBody") }
    public static var helpHistoryTabHeading: String { tr("helpHistoryTabHeading") }
    public static var helpHistoryTabBody: String { tr("helpHistoryTabBody") }
    public static var helpCollapseHeading: String { tr("helpCollapseHeading") }
    public static var helpCollapseBody: String { tr("helpCollapseBody") }
    public static var helpBulletRecentlyPlayed: String { tr("helpBulletRecentlyPlayed") }
    public static var helpBulletLineIn: String { tr("helpBulletLineIn") }
    public static var helpAppleMusicHeading: String { tr("helpAppleMusicHeading") }
    public static var helpAppleMusicBody: String { tr("helpAppleMusicBody") }
    public static var helpPlexHeading: String { tr("helpPlexHeading") }
    public static var helpPlexBody: String { tr("helpPlexBody") }
    public static var helpMusicServicesTopic: String { tr("helpMusicServicesTopic") }
    public static var helpMusicServicesHeading: String { tr("helpMusicServicesHeading") }
    public static var helpMusicServicesBody: String { tr("helpMusicServicesBody") }
    public static var helpStatusDotsHeading: String { tr("helpStatusDotsHeading") }
    public static var helpStatusDotsBody: String { tr("helpStatusDotsBody") }
    public static var helpBulletDotBlue: String { tr("helpBulletDotBlue") }
    public static var helpBulletDotGreen: String { tr("helpBulletDotGreen") }
    public static var helpBulletDotYellow: String { tr("helpBulletDotYellow") }
    public static var helpBulletDotRed: String { tr("helpBulletDotRed") }
    public static var helpBulletDotGray: String { tr("helpBulletDotGray") }
    public static var helpServiceSetupHeading: String { tr("helpServiceSetupHeading") }
    public static var helpServiceSetupBody: String { tr("helpServiceSetupBody") }
    public static var helpServiceNotesHeading: String { tr("helpServiceNotesHeading") }
    public static var helpServiceNotesBody: String { tr("helpServiceNotesBody") }
    public static var helpBulletColors: String { tr("helpBulletColors") }
    public static var helpBulletLanguage: String { tr("helpBulletLanguage") }
    public static var helpBulletMouseControls: String { tr("helpBulletMouseControls") }
    public static var helpBulletDiscoveryMode: String { tr("helpBulletDiscoveryMode") }
    public static var helpBulletDiscoveryHopLimit: String { tr("helpBulletDiscoveryHopLimit") }
    public static var helpBulletSeedAddresses: String { tr("helpBulletSeedAddresses") }
    public static var helpBulletScrobbling: String { tr("helpBulletScrobbling") }
    public static var helpBulletImageCache: String { tr("helpBulletImageCache") }

    // MARK: - Stats dashboard & filters
    public static var statTotalPlays: String { tr("statTotalPlays") }
    public static var statHoursListened: String { tr("statHoursListened") }
    public static var statArtists: String { tr("statArtists") }
    public static var statStreak: String { tr("statStreak") }
    public static var statBest: String { tr("statBest") }
    public static var statAvgPerDay: String { tr("statAvgPerDay") }
    public static var statAlbums: String { tr("statAlbums") }
    public static var statStations: String { tr("statStations") }
    public static var statStarred: String { tr("statStarred") }
    public static var dashboard: String { tr("dashboard") }
    public static var historyTab: String { tr("historyTab") }
    public static var allTime: String { tr("allTime") }
    public static var today: String { tr("today") }
    public static var thisWeek: String { tr("thisWeek") }
    public static var thisMonth: String { tr("thisMonth") }
    public static var threeMonths: String { tr("threeMonths") }
    public static var customRange: String { tr("customRange") }
    public static var allRooms: String { tr("allRooms") }
    public static var allSources: String { tr("allSources") }
    public static var searchTracksPlaceholder: String { tr("searchTracksPlaceholder") }

    // MARK: - Shared UI actions & labels (v3.7)
    public static var pause: String { tr("pause") }
    public static var save: String { tr("save") }
    public static var edit: String { tr("edit") }
    public static var reset: String { tr("reset") }
    public static var search: String { tr("search") }
    public static var name: String { tr("name") }
    public static var next: String { tr("next") }
    public static var previous: String { tr("previous") }
    public static var skipBack15: String { tr("skipBack15") }
    public static var skipForward15: String { tr("skipForward15") }
    public static var skipBack30: String { tr("skipBack30") }
    public static var skipForward30: String { tr("skipForward30") }
    public static var crossfade: String { tr("crossfade") }
    public static var starVerb: String { tr("starVerb") }
    public static var unstarVerb: String { tr("unstarVerb") }
    public static var starThisTrack: String { tr("starThisTrack") }
    public static var refresh: String { tr("refresh") }
    public static var apply: String { tr("apply") }
    public static var moveUp: String { tr("moveUp") }
    public static var moveDown: String { tr("moveDown") }

    // MARK: - Room/Group context menu
    public static var editGroupEllipsis: String { tr("editGroupEllipsis") }
    public static var homeTheaterEQEllipsis: String { tr("homeTheaterEQEllipsis") }

    // MARK: - Menu bar / sidebar context
    public static var notPlaying: String { tr("notPlaying") }
    public static var openChoragus: String { tr("openChoragus") }
    public static var pauseAll: String { tr("pauseAll") }
    public static var resumeAll: String { tr("resumeAll") }

    // MARK: - Home Theater EQ screen
    public static var homeTheaterEQTitle: String { tr("homeTheaterEQTitle") }
    public static var noHomeTheaterZones: String { tr("noHomeTheaterZones") }
    public static var eqTab: String { tr("eqTab") }
    public static var subTab: String { tr("subTab") }
    public static var surroundsTab: String { tr("surroundsTab") }
    public static var nightMode: String { tr("nightMode") }
    public static var dialogEnhancement: String { tr("dialogEnhancement") }
    public static var subOn: String { tr("subOn") }
    public static var subLevel: String { tr("subLevel") }
    public static var placementAdjustment: String { tr("placementAdjustment") }
    public static var surroundsOn: String { tr("surroundsOn") }
    public static var tvLevel: String { tr("tvLevel") }
    public static var musicLevel: String { tr("musicLevel") }
    public static var musicPlayback: String { tr("musicPlayback") }
    public static var surroundModeFull: String { tr("surroundModeFull") }
    public static var surroundModeAmbient: String { tr("surroundModeAmbient") }
    public static var mute: String { tr("mute") }
    public static var unmute: String { tr("unmute") }

    // MARK: - Alarms
    public static var newAlarm: String { tr("newAlarm") }
    public static var editAlarm: String { tr("editAlarm") }
    public static var createAlarmButton: String { tr("createAlarmButton") }
    public static var saveChanges: String { tr("saveChanges") }
    public static var alarmTime: String { tr("alarmTime") }
    public static var alarmRepeat: String { tr("alarmRepeat") }
    public static var everyDay: String { tr("everyDay") }
    public static var weekdays: String { tr("weekdays") }
    public static var weekends: String { tr("weekends") }
    public static var onceLabel: String { tr("onceLabel") }
    public static var roomLabel: String { tr("roomLabel") }
    public static var includeGroupedSpeakers: String { tr("includeGroupedSpeakers") }
    public static var volumeLabel: String { tr("volumeLabel") }
    public static var durationLabel: String { tr("durationLabel") }
    public static var minutes15: String { tr("minutes15") }
    public static var minutes30: String { tr("minutes30") }
    public static var hours3: String { tr("hours3") }

    // MARK: - Preset editor
    public static var editPreset: String { tr("editPreset") }
    public static var speakersAndVolumes: String { tr("speakersAndVolumes") }
    public static var includeEQ: String { tr("includeEQ") }
    public static var includeEQSettings: String { tr("includeEQSettings") }
    public static var loadCurrentEQ: String { tr("loadCurrentEQ") }
    public static var lead: String { tr("lead") }
    public static var speakerEQ: String { tr("speakerEQ") }
    public static var homeTheaterEQSection: String { tr("homeTheaterEQSection") }
    public static var playbackLabel: String { tr("playbackLabel") }
    public static var coordinatorLabel: String { tr("coordinatorLabel") }

    // MARK: - Browse & Search
    public static var localLibrary: String { tr("localLibrary") }
    public static var addToPlaylistMenu: String { tr("addToPlaylistMenu") }
    public static var renamePlaylist: String { tr("renamePlaylist") }
    public static var deletePlaylist: String { tr("deletePlaylist") }
    public static var sortLabel: String { tr("sortLabel") }
    public static var searchAppleMusicPlaceholder: String { tr("searchAppleMusicPlaceholder") }
    public static var searchStationsPlaceholder: String { tr("searchStationsPlaceholder") }
    public static var noStationsFound: String { tr("noStationsFound") }
    public static var searchForRadioStations: String { tr("searchForRadioStations") }
    public static var noChannelsAvailable: String { tr("noChannelsAvailable") }
    public static func searchServicePlaceholder(_ service: String) -> String {
        String(format: tr("searchServicePlaceholderFormat"), service)
    }
    public static func confirmDeleteItem(_ title: String) -> String {
        String(format: tr("confirmDeleteItemFormat"), title)
    }

    // MARK: - Artwork search
    public static var searchArtworkTitle: String { tr("searchArtworkTitle") }
    public static var artistFieldLabel: String { tr("artistFieldLabel") }
    public static var titleFieldLabel: String { tr("titleFieldLabel") }
    public static var albumFieldLabel: String { tr("albumFieldLabel") }
    public static var useThisArtwork: String { tr("useThisArtwork") }

    // MARK: - Queue
    public static var shuffleQueueTooltip: String { tr("shuffleQueueTooltip") }
    public static var saveAsPlaylist: String { tr("saveAsPlaylist") }
    public static var saveToAppleMusic: String { tr("saveToAppleMusic") }
    public static var saveToPlaylist: String { tr("saveToPlaylist") }
    public static var queueHistory: String { tr("queueHistory") }
    public static var restoreQueue: String { tr("restoreQueue") }
    public static var noQueueHistory: String { tr("noQueueHistory") }
    public static var savedQueues: String { tr("savedQueues") }
    public static var queueLibrary: String { tr("queueLibrary") }
    public static var queueLibraryWindowTitle: String { tr("queueLibraryWindowTitle") }
    public static var cloneToChoragus: String { tr("cloneToChoragus") }
    public static var emptyQueueLibrary: String { tr("emptyQueueLibrary") }
    public static var queueAppend: String { tr("queueAppend") }
    public static var queueReplace: String { tr("queueReplace") }
    public static var removeDuplicates: String { tr("removeDuplicates") }
    public static var filterQueuePlaceholder: String { tr("filterQueuePlaceholder") }
    public static var noSavedQueues: String { tr("noSavedQueues") }
    public static var saveQueueTitle: String { tr("saveQueueTitle") }
    public static var saveDestination: String { tr("saveDestination") }
    public static var sonosDestination: String { tr("sonosDestination") }
    public static func queueSource(_ sources: String) -> String {
        String(format: tr("queueSourceFormat"), sources)
    }
    public static var appleMusicSaveFailed: String { tr("appleMusicSaveFailed") }
    public static func savedToAppleMusic(_ count: Int) -> String {
        String(format: tr("savedToAppleMusicFormat"), count)
    }
    public static var shufflingEllipsis: String { tr("shufflingEllipsis") }
    public static var addingToQueueEllipsis: String { tr("addingToQueueEllipsis") }
    public static var loadingQueueEllipsis: String { tr("loadingQueueEllipsis") }
    public static var dragTracksHere: String { tr("dragTracksHere") }
    public static var playlistNamePlaceholder: String { tr("playlistNamePlaceholder") }

    // MARK: - Apple Music (MusicKit) connect-row + detail views
    public static var amConnected: String { tr("amConnected") }
    public static func amConnectedStorefront(_ s: String) -> String { String(format: tr("amConnectedStorefrontFormat"), s) }
    public static var amPermissionDenied: String { tr("amPermissionDenied") }
    public static var amNoActiveSubscription: String { tr("amNoActiveSubscription") }
    public static var amNotConnected: String { tr("amNotConnected") }
    public static var amNotAvailableInBuild: String { tr("amNotAvailableInBuild") }
    public static var amDetailConnected: String { tr("amDetailConnected") }
    public static var amDetailDenied: String { tr("amDetailDenied") }
    public static var amDetailNoSubscription: String { tr("amDetailNoSubscription") }
    public static var amDetailNotConnected: String { tr("amDetailNotConnected") }
    public static var amActionInProgress: String { tr("amActionInProgress") }
    public static func amPlaying(_ name: String) -> String { String(format: tr("amPlayingFormat"), name) }
    public static func amQueueingNext(_ name: String) -> String { String(format: tr("amQueueingNextFormat"), name) }
    public static func amAddingToQueue(_ name: String) -> String { String(format: tr("amAddingToQueueFormat"), name) }
    public static func amPlayingTopSongs(_ name: String) -> String { String(format: tr("amPlayingTopSongsFormat"), name) }
    public static func amQueueingTopSongsNext(_ name: String) -> String { String(format: tr("amQueueingTopSongsNextFormat"), name) }
    public static func amAddingTopSongsToQueue(_ name: String) -> String { String(format: tr("amAddingTopSongsToQueueFormat"), name) }
    public static func amPlayingTracks(_ count: Int) -> String { String(format: tr("amPlayingTracksFormat"), count) }
    public static func amAddingTracksToQueue(_ count: Int) -> String { String(format: tr("amAddingTracksToQueueFormat"), count) }
    public static func amQueueingTracksNext(_ count: Int) -> String { String(format: tr("amQueueingTracksNextFormat"), count) }
    public static var amPlayAll: String { tr("amPlayAll") }
    public static var amAddAllToQueue: String { tr("amAddAllToQueue") }
    public static var amTopSongs: String { tr("amTopSongs") }
    public static var amTopAlbums: String { tr("amTopAlbums") }
    public static var amTopPlaylists: String { tr("amTopPlaylists") }
    public static var amAlbums: String { tr("amAlbums") }
    public static var amStations: String { tr("amStations") }
    public static var amNoTracks: String { tr("amNoTracks") }
    public static var amNothingToShow: String { tr("amNothingToShow") }
    public static var amFilterGenres: String { tr("amFilterGenres") }
    public static var amNoChartsForGenre: String { tr("amNoChartsForGenre") }
    public static var amSearchHint: String { tr("amSearchHint") }
    // Plain %d count label; iOS inflect: AttributedString form dropped for cross-platform consistency.
    public static func amItemsCount(_ n: Int) -> String { String(format: tr("amItemsCountFormat"), n) }
    /// Item count under a bulk-action bar, every list.
    public static func itemsCount(_ n: Int) -> String { String(format: tr("amItemsCountFormat"), n) }
    public static var amPlaylists: String { tr("amPlaylists") }
    public static var amPlaylistBadge: String { tr("amPlaylistBadge") }
    public static var amEmptyPlaylist: String { tr("amEmptyPlaylist") }
    public static var amSearchStationsPlaceholder: String { tr("amSearchStationsPlaceholder") }
    public static var amSearchAppleMusicStations: String { tr("amSearchAppleMusicStations") }
    public static var amNoStationsFound: String { tr("amNoStationsFound") }
    public static var amSortDefault: String { tr("amSortDefault") }
    public static var amSortName: String { tr("amSortName") }
    public static var amSortLiveFirst: String { tr("amSortLiveFirst") }
    public static var amSortTitle: String { tr("amSortTitle") }
    public static var amSortArtist: String { tr("amSortArtist") }
    public static var amSortAlbum: String { tr("amSortAlbum") }
    public static var amSortDuration: String { tr("amSortDuration") }
    public static var amSortNewest: String { tr("amSortNewest") }
    public static var amSortOldest: String { tr("amSortOldest") }
    public static var amSortRecentlyAdded: String { tr("amSortRecentlyAdded") }
    public static var amSortFirstAdded: String { tr("amSortFirstAdded") }
    public static var amSortLabelPlain: String { tr("amSortLabelPlain") }
    public static func amSortLabel(_ s: String) -> String { String(format: tr("amSortLabelFormat"), s) }
    // MusicKit browse/search section headers + connect button + search placeholder.
    public static var amConnectAppleMusic: String { tr("amConnectAppleMusic") }
    public static var amYourLibrary: String { tr("amYourLibrary") }
    public static var amRecentlyPlayed: String { tr("amRecentlyPlayed") }
    public static var amMadeForYou: String { tr("amMadeForYou") }
    public static var amCharts: String { tr("amCharts") }
    public static var amBrowse: String { tr("amBrowse") }
    public static var amSearchAppleMusic: String { tr("amSearchAppleMusic") }
    public static var amSongs: String { tr("amSongs") }
    public static var amArtists: String { tr("amArtists") }
    // MusicKit browse extras + search empty states + auth prompt copy.
    public static var amGenres: String { tr("amGenres") }
    public static var amStationsForYou: String { tr("amStationsForYou") }
    public static var amRadioStations: String { tr("amRadioStations") }
    public static var amNowInSpatialAudio: String { tr("amNowInSpatialAudio") }
    public static var amSpatialAudio: String { tr("amSpatialAudio") }
    public static var amLibrarySongs: String { tr("amLibrarySongs") }
    public static var amLibraryAlbums: String { tr("amLibraryAlbums") }
    public static var amLibraryArtists: String { tr("amLibraryArtists") }
    public static var amLibraryPlaylists: String { tr("amLibraryPlaylists") }
    public static var amSeeAllSongs: String { tr("amSeeAllSongs") }
    public static var amSeeAllAlbums: String { tr("amSeeAllAlbums") }
    public static var amSeeAllArtists: String { tr("amSeeAllArtists") }
    public static var amSeeAllPlaylists: String { tr("amSeeAllPlaylists") }
    public static var amSearchPrompt: String { tr("amSearchPrompt") }
    public static var amSearchCatalogPrompt: String { tr("amSearchCatalogPrompt") }
    public static var amNoResults: String { tr("amNoResults") }
    public static var amTryDifferentQuery: String { tr("amTryDifferentQuery") }
    public static var amNoTracksMatched: String { tr("amNoTracksMatched") }
    public static var amNoAlbums: String { tr("amNoAlbums") }
    public static var amNoAlbumsMatched: String { tr("amNoAlbumsMatched") }
    public static var amNoArtists: String { tr("amNoArtists") }
    public static var amNoArtistsMatched: String { tr("amNoArtistsMatched") }
    public static var amNoPlaylists: String { tr("amNoPlaylists") }
    public static var amNoPlaylistsMatched: String { tr("amNoPlaylistsMatched") }
    public static var amAccessDeniedTitle: String { tr("amAccessDeniedTitle") }
    public static var amSubscriptionRequiredTitle: String { tr("amSubscriptionRequiredTitle") }
    public static var amNotAvailableTitle: String { tr("amNotAvailableTitle") }
    public static var amPromptBodyNotDetermined: String { tr("amPromptBodyNotDetermined") }
    public static var amPromptBodyDenied: String { tr("amPromptBodyDenied") }
    public static var amPromptBodyNoSubscription: String { tr("amPromptBodyNoSubscription") }
    public static var amPromptBodyNotApplicable: String { tr("amPromptBodyNotApplicable") }

    // MARK: - Play history context menu
    public static var copyTrackDetails: String { tr("copyTrackDetails") }
    public static var copyTitle: String { tr("copyTitle") }
    public static var copyArtist: String { tr("copyArtist") }
    public static func filterByArtist(_ artist: String) -> String {
        String(format: tr("filterByArtistFormat"), artist)
    }
    public static func filterByRoom(_ room: String) -> String {
        String(format: tr("filterByRoomFormat"), room)
    }
    public static func filterBySource(_ source: String) -> String {
        String(format: tr("filterBySourceFormat"), source)
    }
    public static var noListeningHistory: String { tr("noListeningHistory") }
    public static var noRecentlyPlayed: String { tr("noRecentlyPlayed") }
    public static var station: String { tr("station") }
    public static var track: String { tr("track") }

    // MARK: - Dashboard tooltips
    public static var refreshDailySummary: String { tr("refreshDailySummary") }
    public static var customThemeEditor: String { tr("customThemeEditor") }
    public static var themeLabel: String { tr("themeLabel") }
    public static var changeCustomColor: String { tr("changeCustomColor") }

    /// Tagline used in About panel credits.
    public static var aboutTagline: String { tr("aboutTagline") }

    // MARK: - Scrobbling (added v3.6)
    //
    // Brand terms that stay English in all locales (per Last.fm's own
    // localized sites): "Scrobble", "Scrobbling", "Last.fm". Translations
    // verified against Apple's macOS localization glossary and standard
    // translations from Spotify / Apple Music UI where analogous concepts
    // exist. Count+noun pairs (pending/sent/ignored/failed) use post-count
    // adjective/noun form for straightforward interpolation.
    public static var scrobbling: String { tr("scrobbling") }
    public static var scrobblingIntro: String { tr("scrobblingIntro") }
    public static var enableLastFM: String { tr("enableLastFM") }
    public static var lastFMCredentialsIntro: String { tr("lastFMCredentialsIntro") }
    public static var openLastFMRegistration: String { tr("openLastFMRegistration") }
    public static var apiKey: String { tr("apiKey") }
    public static var sharedSecret: String { tr("sharedSecret") }
    public static var apiKeyPlaceholder: String { tr("apiKeyPlaceholder") }
    public static var sharedSecretPlaceholder: String { tr("sharedSecretPlaceholder") }
    public static var testCredentials: String { tr("testCredentials") }
    public static var credentialsValid: String { tr("credentialsValid") }
    public static var waitingForBrowser: String { tr("waitingForBrowser") }
    public static var connectToLastFM: String { tr("connectToLastFM") }
    public static var disconnect: String { tr("disconnect") }
    public static var doubleScrobbleWarning: String { tr("doubleScrobbleWarning") }
    public static var sources: String { tr("sources") }
    public static var sourcesDescription: String { tr("sourcesDescription") }
    public static var noRoomsInHistory: String { tr("noRoomsInHistory") }
    public static var musicServicesToScrobble: String { tr("musicServicesToScrobble") }
    public static var musicServicesDescription: String { tr("musicServicesDescription") }
    public static var autoScrobbleEveryFiveMinutes: String { tr("autoScrobbleEveryFiveMinutes") }
    public static var scrobblePendingNow: String { tr("scrobblePendingNow") }
    public static var scrobblingProgress: String { tr("scrobblingProgress") }
    public static var pending: String { tr("pending") }
    public static var sent: String { tr("sent") }
    public static var ignored: String { tr("ignored") }
    public static var failed: String { tr("failed") }
    public static var resetIgnored: String { tr("resetIgnored") }
    public static var resetIgnoredTooltip: String { tr("resetIgnoredTooltip") }
    public static var lastRunLabel: String { tr("lastRunLabel") }
    public static var recentNonScrobbled: String { tr("recentNonScrobbled") }
    public static var noReasonRecorded: String { tr("noReasonRecorded") }

    // MARK: - Browse context menus + service settings (v3.7)
    public static var replaceQueue: String { tr("replaceQueue") }
    public static var showTracks: String { tr("showTracks") }
    public static var playAll: String { tr("playAll") }
    public static var addAllToQueue: String { tr("addAllToQueue") }
    public static var connect: String { tr("connect") }
    public static var signOut: String { tr("signOut") }
    public static var active: String { tr("active") }
    public static var needsFavorite: String { tr("needsFavorite") }
    public static var noResultsFound: String { tr("noResultsFound") }
    public static var searching: String { tr("searching") }
    public static var searchLabel: String { tr("searchLabel") }
    public static var rename: String { tr("rename") }

    // MARK: - Music Services settings + Help sheet (v3.7)
    public static var searchServicesHeader: String { tr("searchServicesHeader") }
    public static var connectedServicesHeader: String { tr("connectedServicesHeader") }
    public static var searchServicesIntroBody: String { tr("searchServicesIntroBody") }
    public static var searchServicesPlaceholder: String { tr("searchServicesPlaceholder") }
    public static var otherServicesBody: String { tr("otherServicesBody") }
    public static var testedConnectedBody: String { tr("testedConnectedBody") }
    public static var serviceAvailability: String { tr("serviceAvailability") }
    public static var musicServicesSetupGuide: String { tr("musicServicesSetupGuide") }
    public static var setupStep1Title: String { tr("setupStep1Title") }
    public static var setupStep1Body: String { tr("setupStep1Body") }
    public static var setupStep2Title: String { tr("setupStep2Title") }
    public static var setupStep2Body: String { tr("setupStep2Body") }
    public static var setupStep3Title: String { tr("setupStep3Title") }
    public static var setupStep3Body: String { tr("setupStep3Body") }
    public static var setupStep4Title: String { tr("setupStep4Title") }
    public static var setupStep4Body: String { tr("setupStep4Body") }
    public static var serviceStatusLabel: String { tr("serviceStatusLabel") }
    public static var statusActiveLine: String { tr("statusActiveLine") }
    public static var statusNeedsFavoriteLine: String { tr("statusNeedsFavoriteLine") }
    public static var statusNotConnectedLine: String { tr("statusNotConnectedLine") }
    public static var whyStep3Header: String { tr("whyStep3Header") }
    public static var whyStep3Body: String { tr("whyStep3Body") }
    public static var blockedServicesHeader: String { tr("blockedServicesHeader") }
    public static var blockedServicesBody: String { tr("blockedServicesBody") }
    public static var blockedFavoritesPlayableHint: String { tr("blockedFavoritesPlayableHint") }
    public static var serviceNotConfigured: String { tr("serviceNotConfigured") }
    public static var setValue: String { tr("setValue") }
    public static var doubleClickToTypeValue: String { tr("doubleClickToTypeValue") }
    public static var addAll: String { tr("addAll") }
    public static var deletePresetTitle: String { tr("deletePresetTitle") }
    public static var clearPlayHistoryTitle: String { tr("clearPlayHistoryTitle") }
    public static func queueLimitReachedSomeNotAdded(_ limit: Int) -> String {
        String(format: tr("queueLimitReachedSomeNotAdded"), limit)
    }
    public static func queueLimitReachedRemainderNotAdded(_ limit: Int) -> String {
        String(format: tr("queueLimitReachedRemainderNotAdded"), limit)
    }
    public static func queueTracksNotAdded(_ count: Int) -> String {
        String(format: tr("queueTracksNotAdded"), count)
    }
    public static func deleteFilteredEntriesTitle(_ count: Int) -> String {
        String(format: tr("deleteFilteredEntriesTitle"), count)
    }
    public static func deletedPresetFormat(_ name: String) -> String {
        String(format: tr("deletedPresetFormat"), name)
    }
    public static func largeAddBuildingTitle(_ count: Int) -> String {
        String(format: tr("largeAddBuildingTitle"), count)
    }
    public static func largeAddReadyTitle(_ count: Int) -> String {
        String(format: tr("largeAddReadyTitle"), count)
    }
    public static var largeAddBuildingBody: String { tr("largeAddBuildingBody") }
    public static var largeAddReadyBody: String { tr("largeAddReadyBody") }
    public static var appleMusicNoteBody: String { tr("appleMusicNoteBody") }
    public static var searchSonosRadioPlaceholder: String { tr("searchSonosRadioPlaceholder") }
    public static var searchSonosRadioEmpty: String { tr("searchSonosRadioEmpty") }
    public static var favorites: String { tr("favorites") }

    // MARK: - Settings / History help text (v3.7)
    public static var classicShuffleHelp: String { tr("classicShuffleHelp") }
    public static var proportionalVolumeHelp: String { tr("proportionalVolumeHelp") }
    public static var dailySummariesHelp: String { tr("dailySummariesHelp") }
    public static var rescanCacheHelp: String { tr("rescanCacheHelp") }
    public static var clearArtCacheHelp: String { tr("clearArtCacheHelp") }
    public static var homeTheaterConnectHelp: String { tr("homeTheaterConnectHelp") }
    public static var homeTheaterTrebleBassHelp: String { tr("homeTheaterTrebleBassHelp") }
    public static var homeTheaterSurroundHelp: String { tr("homeTheaterSurroundHelp") }
    public static var presetSaveHelp: String { tr("presetSaveHelp") }
    public static var presetSetupHint: String { tr("presetSetupHint") }
    public static var historyIntroBody: String { tr("historyIntroBody") }
    public static var historyTracksAppear: String { tr("historyTracksAppear") }
    public static var statsAppearHere: String { tr("statsAppearHere") }
    public static var searchForSongsAlbumsArtists: String { tr("searchForSongsAlbumsArtists") }
    public static var artworkNoResults: String { tr("artworkNoResults") }

    public static func deleteFilteredWarning(_ count: Int) -> String {
        String(format: tr("deleteFilteredWarningFormat"), count)
    }
    public static func deleteAllWarning(_ count: Int) -> String {
        String(format: tr("deleteAllWarningFormat"), count)
    }
    public static func selectArtworkHeader(_ count: Int) -> String {
        String(format: tr("selectArtworkHeaderFormat"), count)
    }

    // MARK: - Stats Dashboard headings (v3.7)
    public static var topArtists: String { tr("topArtists") }
    public static var topSources: String { tr("topSources") }
    public static var topTracks: String { tr("topTracks") }
    public static var topStations: String { tr("topStations") }
    public static var topAlbums: String { tr("topAlbums") }
    public static var recentActivity: String { tr("recentActivity") }
    public static var listeningActivity: String { tr("listeningActivity") }
    public static var peakListeningHours: String { tr("peakListeningHours") }
    public static var roomUsage: String { tr("roomUsage") }
    public static var dayOfWeek: String { tr("dayOfWeek") }
    public static var refreshStats: String { tr("refreshStats") }
    public static var updatingEllipsis: String { tr("updatingEllipsis") }
    public static var rebuildAllSummaries: String { tr("rebuildAllSummaries") }
    public static var noListeningDataYet: String { tr("noListeningDataYet") }
    public static var noData: String { tr("noData") }
    public static var noStationData: String { tr("noStationData") }
    public static var buildingSummaries: String { tr("buildingSummaries") }
    public static var manualOnly: String { tr("manualOnly") }
    public static var intervalLabel: String { tr("intervalLabel") }
    public static func historyStats(entries: Int, hours: Double) -> String {
        String(format: tr("historyStatsFormat"), entries, hours)
    }
    public static var never_: String { tr("never") }
    public static func last30DaysAverage(_ avg: Int) -> String {
        String(format: tr("last30DaysAverageFormat"), avg)
    }
    public static func peakHourFormat(_ hour: String) -> String {
        String(format: tr("peakHourFormat"), hour)
    }

    // MARK: - Settings (Display/Music tab extras v3.7)
    public static var displayTab: String { tr("displayTab") }
    public static var musicTab: String { tr("musicTab") }
    public static var systemTab: String { tr("systemTab") }

    // MARK: - Visualisations tab (v4.8)
    public static var visualisationsTab: String { tr("visualisationsTab") }
    public static var visGenreMatching: String { tr("visGenreMatching") }
    public static var visGenreMatchPartial: String { tr("visGenreMatchPartial") }
    public static var visGenreMatchFull: String { tr("visGenreMatchFull") }
    public static var visRandomArtMix: String { tr("visRandomArtMix") }
    public static var visShowAboutPanel: String { tr("visShowAboutPanel") }
    public static var visHistorySource: String { tr("visHistorySource") }
    public static var visHistorySourceGroup: String { tr("visHistorySourceGroup") }
    public static var visHistorySourceAll: String { tr("visHistorySourceAll") }
    // Back of the Club section + per-setting help captions
    public static var visBackOfTheClubSection: String { tr("visBackOfTheClubSection") }
    public static var visGenreMatchingHelp: String { tr("visGenreMatchingHelp") }
    public static var visRandomArtMixHelp: String { tr("visRandomArtMixHelp") }
    public static var visShowAboutPanelHelp: String { tr("visShowAboutPanelHelp") }
    public static var visHistorySourceHelp: String { tr("visHistorySourceHelp") }
    // Club Vis lighting colour scheme (Settings)
    public static var visColourScheme: String { tr("visColourScheme") }
    public static var visColourSchemeHelp: String { tr("visColourSchemeHelp") }
    public static var visColourSchemeAlbumArt: String { tr("visColourSchemeAlbumArt") }
    public static var visColourSchemeChoragus: String { tr("visColourSchemeChoragus") }
    public static var visColourSchemeCustom: String { tr("visColourSchemeCustom") }
    public static var visCustomToneWash: String { tr("visCustomToneWash") }
    public static var visCustomToneBeamA: String { tr("visCustomToneBeamA") }
    public static var visCustomToneBeamB: String { tr("visCustomToneBeamB") }
    public static var visCustomToneAccent: String { tr("visCustomToneAccent") }
    // Visualisation menu (top-level + toolbar dropdown)
    public static var visualisationMenu: String { tr("visualisationMenu") }
    // ABOUT label on the visualisation's artist panel header
    public static var aboutSectionLabel: String { tr("aboutSectionLabel") }
    // Memorial overlay splash text (Choragus 2006-2015 in-memory)
    public static var memorialOverlayTitle: String { tr("memorialOverlayTitle") }
    public static var memorialOverlayIYKYK: String { tr("memorialOverlayIYKYK") }

    // MARK: - History data cap (v4.8)
    public static var historyDataCap: String { tr("historyDataCap") }
    public static var unlimited: String { tr("unlimited") }
    public static var playbackSection: String { tr("playbackSection") }
    public static var musicServicesBeta: String { tr("musicServicesBeta") }
    public static var menuBarControls: String { tr("menuBarControls") }
    public static var classicShuffleMode: String { tr("classicShuffleMode") }
    public static var proportionalGroupVolume: String { tr("proportionalGroupVolume") }
    public static var ignoreTVHDMILineIn: String { tr("ignoreTVHDMILineIn") }
    public static var realtimeDashboardSummaries: String { tr("realtimeDashboardSummaries") }
    public static var aboutNetworkBody: String { tr("aboutNetworkBody") }
    public static var aboutCacheBody: String { tr("aboutCacheBody") }
    public static var clearSpeakerCachePrompt: String { tr("clearSpeakerCachePrompt") }
    public static var clearArtworkCachePrompt: String { tr("clearArtworkCachePrompt") }
    public static var clearPlayHistoryPrompt: String { tr("clearPlayHistoryPrompt") }
    public static func lastUpdatedFormat(_ time: String) -> String {
        String(format: tr("lastUpdatedFormat"), time)
    }
    public static func artworkImagesSummary(_ diskUsage: String, _ fileCount: Int) -> String {
        String(format: tr("artworkImagesSummaryFormat"), diskUsage, fileCount)
    }

    public static func waitingForService(_ name: String) -> String {
        String(format: tr("waitingForServiceFormat"), name)
    }
    public static func otherServicesAvailable(_ count: Int) -> String {
        String(format: tr("otherServicesAvailableFormat"), count)
    }

    // MARK: - NowPlaying popovers / menus (reviewed v3.6)
    public static var shuffleDisabledTitle: String { tr("shuffleDisabledTitle") }
    public static var shuffleDisabledBody: String { tr("shuffleDisabledBody") }
    public static var searchArtwork: String { tr("searchArtwork") }
    public static var ignoreArtwork: String { tr("ignoreArtwork") }
    public static var close: String { tr("close") }

    /// Locale matching the user's current app-language preference. Use this
    /// as `DateFormatter.locale` / `NumberFormatter.locale` anywhere in the
    /// app that renders localized date or number strings, so they follow the
    /// app's language setting rather than the macOS system locale (which can
    /// differ when the user overrides language in Settings).
    public static var currentLocale: Locale {
        let code = UserDefaults.standard.string(forKey: UDKey.appLanguage) ?? "en"
        return Locale(identifier: code)
    }

    // MARK: - Filter preview (v3.6)
    public static var filterPreviewTitle: String { tr("filterPreviewTitle") }
    public static var wouldSend: String { tr("wouldSend") }
    public static var roomBlocked: String { tr("roomBlocked") }
    public static var serviceBlocked: String { tr("serviceBlocked") }
    public static var structuralIneligible: String { tr("structuralIneligible") }
    public static var roomBlockedExamples: String { tr("roomBlockedExamples") }
    public static var serviceBlockedExamples: String { tr("serviceBlockedExamples") }
    public static var currentFilterPrefix: String { tr("currentFilterPrefix") }

    // MARK: - v4.0 inline string localization
    public static var mouseControls: String { tr("mouseControls") }
    public static var librarySharesHeader: String { tr("librarySharesHeader") }
    public static var libraryShareHint: String { tr("libraryShareHint") }
    public static var noLibrarySharesConfigured: String { tr("noLibrarySharesConfigured") }
    public static var keyboardControls: String { tr("keyboardControls") }
    public static var mediaKeysEnabled: String { tr("mediaKeysEnabled") }
    public static var mediaKeysEnabledHint: String { tr("mediaKeysEnabledHint") }
    public static var scrollWheelAdjustsVolume: String { tr("scrollWheelAdjustsVolume") }
    public static var scrollWheelAdjustsVolumeHint: String { tr("scrollWheelAdjustsVolumeHint") }
    public static var middleClickTogglesMute: String { tr("middleClickTogglesMute") }
    public static var middleClickTogglesMuteHint: String { tr("middleClickTogglesMuteHint") }
    public static func pendingWithFilteredFormat(pending: Int, filtered: Int) -> String {
        String(format: tr("pendingWithFilteredFormat"), pending, filtered)
    }
    public static var firstTimeHereSetupSteps: String { tr("firstTimeHereSetupSteps") }
    public static var checkingSonosHousehold: String { tr("checkingSonosHousehold") }
    public static var noServicesConnectedYet: String { tr("noServicesConnectedYet") }
    public static var localMusicLibraryHeader: String { tr("localMusicLibraryHeader") }
    public static var updateLibraryIndex: String { tr("updateLibraryIndex") }
    public static var updateLibraryIndexHint: String { tr("updateLibraryIndexHint") }
    public static var noLocalLibraryFound: String { tr("noLocalLibraryFound") }
    public static func reindexingSystems(_ count: Int) -> String {
        String(format: tr("reindexingSystemsFormat"), count)
    }
    public static var fixedLineOutVolume: String { tr("fixedLineOutVolume") }
    public static var fixedShort: String { tr("fixedShort") }
    public static var fixedVolume: String { tr("fixedVolume") }
    public static var roomMatchIncludes: String { tr("roomMatchIncludes") }
    public static var roomMatchExact: String { tr("roomMatchExact") }
    public static var legendAvailable: String { tr("legendAvailable") }
    public static var legendUntested: String { tr("legendUntested") }
    public static var legendUnavailable: String { tr("legendUnavailable") }
    public static var openGitHubIssues: String { tr("openGitHubIssues") }
    public static func playAnySongAndFavoriteFormat(_ serviceName: String) -> String {
        String(format: tr("playAnySongAndFavoriteFormat"), serviceName)
    }
    public static var connectToPlex: String { tr("connectToPlex") }
    public static var plexRelayReturnedNoItems: String { tr("plexRelayReturnedNoItems") }
    public static var localNetworkAccessRequired: String { tr("localNetworkAccessRequired") }
    public static var openSystemSettings: String { tr("openSystemSettings") }
    public static var reCheck: String { tr("reCheck") }
    public static var localNetworkAccessMessage: String { tr("localNetworkAccessMessage") }
    public static var playAllNow: String { tr("playAllNow") }

    // About box
    public static var aboutWindowTitle: String { tr("aboutWindowTitle") }
    public static var etymologyType: String { tr("etymologyType") }
    public static var etymologyDefinition: String { tr("etymologyDefinition") }
    public static var choragusMotto: String { tr("choragusMotto") }
    public static var credits: String { tr("credits") }
    public static var dataSources: String { tr("dataSources") }
    public static var dataSourcesCaption: String { tr("dataSourcesCaption") }
    public static var contributors: String { tr("contributors") }
    public static var contributorsCaption: String { tr("contributorsCaption") }
    public static var notAffiliatedWithSonos: String { tr("notAffiliatedWithSonos") }

    // Now Playing context panel
    public static var lookingUpLyrics: String { tr("lookingUpLyrics") }
    public static var noLyricsFound: String { tr("noLyricsFound") }
    public static func couldNotLoadLyricsFormat(_ msg: String) -> String {
        String(format: tr("couldNotLoadLyricsFormat"), msg)
    }
    public static var instrumental: String { tr("instrumental") }
    public static var refreshMetadata: String { tr("refreshMetadata") }
    public static var loadingInfo: String { tr("loadingInfo") }
    public static var noInfoFound: String { tr("noInfoFound") }
    public static var readOnWikipedia: String { tr("readOnWikipedia") }
    public static var similarArtists: String { tr("similarArtists") }
    public static var clickToEnlarge: String { tr("clickToEnlarge") }
    public static var noPreviousPlaysInHistory: String { tr("noPreviousPlaysInHistory") }
    public static var recentPlays: String { tr("recentPlays") }
    public static func playsCountFormat(_ count: Int) -> String {
        String(format: tr("playsCountFormat"), count)
    }
    public static func acrossRoomsFormat(count: Int, list: String) -> String {
        String(format: tr("acrossRoomsFormat"), count, list)
    }
    public static func lastPlayedFormat(_ when: String) -> String {
        String(format: tr("lastPlayedFormat"), when)
    }
    public static var tabLyrics: String { tr("tabLyrics") }
    public static var tabAbout: String { tr("tabAbout") }
    public static var tabHistory: String { tr("tabHistory") }

    // Appearance modes
    public static var appearanceLight: String { tr("appearanceLight") }
    public static var appearanceDark: String { tr("appearanceDark") }

    // Context panel collapse toggle
    public static var showLyricsAboutHistory: String { tr("showLyricsAboutHistory") }
    public static var hideLyricsAboutHistory: String { tr("hideLyricsAboutHistory") }

    // Plex Direct browse actions + retry
    public static var open: String { tr("open") }
    public static var retry: String { tr("retry") }
    public static var usePlexViaSonosRelay: String { tr("usePlexViaSonosRelay") }
    public static var playAllNext: String { tr("playAllNext") }
    public static var clearAll: String { tr("clearAll") }

    // Visualisations menu + ForFunView strings
    public static var visualisations: String { tr("visualisations") }
    public static var tapToResetOffset: String { tr("tapToResetOffset") }
    public static var popOutLyrics: String { tr("popOutLyrics") }
    public static var karaoke: String { tr("karaoke") }
    public static var karaokeSection: String { tr("karaokeSection") }
    public static var karaokeStyleLabel: String { tr("karaokeStyleLabel") }
    public static var karaokeStyleHelp: String { tr("karaokeStyleHelp") }
    public static var karaokeStyleDynamic: String { tr("karaokeStyleDynamic") }
    public static var karaokeStyleClassic: String { tr("karaokeStyleClassic") }
    public static var audioFormatAtmos: String { tr("audioFormatAtmos") }
    public static var audioFormatLossless: String { tr("audioFormatLossless") }
    public static var tvAudioStereoPCM: String { tr("tvAudioStereoPCM") }
    public static var tvAudioMultichannelPCM51: String { tr("tvAudioMultichannelPCM51") }
    public static var tvAudioMultichannelPCM71: String { tr("tvAudioMultichannelPCM71") }
    public static var tvAudioDolbyDigital51: String { tr("tvAudioDolbyDigital51") }
    public static var tvAudioDolbyDigitalPlus71: String { tr("tvAudioDolbyDigitalPlus71") }
    public static var tvAudioDolbyAtmosTrueHD71: String { tr("tvAudioDolbyAtmosTrueHD71") }
    public static var tvAudioDTSSurround51: String { tr("tvAudioDTSSurround51") }

    // Diagnostics
    public static var diagnostics: String { tr("diagnostics") }
    public static var hideDiagnosticsIcon: String { tr("hideDiagnosticsIcon") }
    public static var hideDiagnosticsIconHint: String { tr("hideDiagnosticsIconHint") }
    public static var diagFilterAll: String { tr("diagFilterAll") }
    public static var diagFilterErrors: String { tr("diagFilterErrors") }
    public static var diagFilterWarningsAndErrors: String { tr("diagFilterWarningsAndErrors") }
    public static var diagColumnTime: String { tr("diagColumnTime") }
    public static var diagColumnLevel: String { tr("diagColumnLevel") }
    public static var diagColumnTag: String { tr("diagColumnTag") }
    public static var diagColumnMessage: String { tr("diagColumnMessage") }
    public static var diagLevelInfo: String { tr("diagLevelInfo") }
    public static var diagLevelWarning: String { tr("diagLevelWarning") }
    public static var diagLevelError: String { tr("diagLevelError") }
    public static var diagCopyAll: String { tr("diagCopyAll") }
    public static var diagSaveBundle: String { tr("diagSaveBundle") }
    public static var diagSaveEncryptedLog: String { tr("diagSaveEncryptedLog") }
    public static var diagSaveEncryptedLogHelp: String { tr("diagSaveEncryptedLogHelp") }
    public static var diagClearAll: String { tr("diagClearAll") }
    public static var diagCopyRow: String { tr("diagCopyRow") }
    public static var diagHelpTitle: String { tr("diagHelpTitle") }
    public static var diagHelpBody: String { tr("diagHelpBody") }
    public static var diagReportOnGitHub: String { tr("diagReportOnGitHub") }
    public static var diagReportOnGitHubHelp: String { tr("diagReportOnGitHubHelp") }
    public static var diagReportPrivately: String { tr("diagReportPrivately") }
    public static var diagReportPrivatelyHelp: String { tr("diagReportPrivatelyHelp") }
    public static var diagCopyRowWithPayload: String { tr("diagCopyRowWithPayload") }
    public static var diagCopyRowWithPayloadHelp: String { tr("diagCopyRowWithPayloadHelp") }
    public static var softwareUpdatesBetaSection: String { tr("softwareUpdatesBetaSection") }
    public static var diagEncryptedReportFailedTitle: String { tr("diagEncryptedReportFailedTitle") }
    public static var diagEncryptedReportFormTitle: String { tr("diagEncryptedReportFormTitle") }
    public static func diagEncryptedReportFormBody(_ bundleFilename: String) -> String {
        String(format: tr("diagEncryptedReportFormBody"), bundleFilename)
    }
    public static var softwareUpdatesBetaOptIn: String { tr("softwareUpdatesBetaOptIn") }
    public static var softwareUpdatesBetaWarning: String { tr("softwareUpdatesBetaWarning") }
    public static var currentVersionLabel: String { tr("currentVersionLabel") }
    public static var openAboutWindowTooltip: String { tr("openAboutWindowTooltip") }
    public static func versionBuildFormat(_ version: String, _ build: String) -> String {
        String(format: tr("versionBuildFormat"), version, build)
    }
    public static var diagEncryptedReportBug: String { tr("diagEncryptedReportBug") }
    public static var diagEncryptedReportBugHelp: String { tr("diagEncryptedReportBugHelp") }
    public static var diagEncryptedReportSecurity: String { tr("diagEncryptedReportSecurity") }
    public static var diagEncryptedReportSecurityHelp: String { tr("diagEncryptedReportSecurityHelp") }
    public static var diagPreviewTitle: String { tr("diagPreviewTitle") }
    public static var diagPreviewSubtitle: String { tr("diagPreviewSubtitle") }
    public static var diagPreviewConfirm: String { tr("diagPreviewConfirm") }
    public static var diagPreviewRedactionNone: String { tr("diagPreviewRedactionNone") }
    public static func diagPreviewRedactionFormat(_ tokens: Int, _ lanIPs: Int, _ paths: Int) -> String {
        String(format: tr("diagPreviewRedactionFormat"), tokens, lanIPs, paths)
    }
    public static func diagCopyRowsWithPayloadFormat(_ count: Int) -> String {
        String(format: tr("diagCopyRowsWithPayloadFormat"), count)
    }
    public static var diagTabLog: String { tr("diagTabLog") }
    public static var diagTabLiveEvents: String { tr("diagTabLiveEvents") }
    public static var diagTabSpeakers: String { tr("diagTabSpeakers") }
    public static var diagTabNetwork: String { tr("diagTabNetwork") }
    public static var diagTabMCP: String { tr("diagTabMCP") }
    public static var mcpBuilds: String { tr("mcpBuilds") }
    public static var mcpColumnToken: String { tr("mcpColumnToken") }
    public static var mcpColumnAction: String { tr("mcpColumnAction") }
    public static var mcpColumnOutcome: String { tr("mcpColumnOutcome") }
    public static var mcpColumnDuration: String { tr("mcpColumnDuration") }
    public static var mcpColumnSummary: String { tr("mcpColumnSummary") }
    public static var mcpRequest: String { tr("mcpRequest") }
    public static var mcpResponse: String { tr("mcpResponse") }
    public static var mcpSelectRow: String { tr("mcpSelectRow") }
    public static var mcpCopyRequest: String { tr("mcpCopyRequest") }
    public static var mcpCopyResponse: String { tr("mcpCopyResponse") }
    public static func mcpFailedAuthFormat(_ count: Int) -> String {
        String(format: tr("mcpFailedAuthFormat"), count)
    }
    public static var diagTabHealth: String { tr("diagTabHealth") }
    public static var diagTabMatrix: String { tr("diagTabMatrix") }
    public static var diagHealthBanner: String { tr("diagHealthBanner") }
    public static var diagMatrixBannerWifiMode: String { tr("diagMatrixBannerWifiMode") }
    public static var diagFilterRooms: String { tr("diagFilterRooms") }
    public static var diagColumnStatus: String { tr("diagColumnStatus") }
    public static var diagColumnSerial: String { tr("diagColumnSerial") }
    public static var diagColumnHardware: String { tr("diagColumnHardware") }
    public static var diagColumnInterference: String { tr("diagColumnInterference") }
    public static var diagStatusOK: String { tr("diagStatusOK") }
    public static var diagStatusCheckWifi: String { tr("diagStatusCheckWifi") }
    public static var diagStatusOffline: String { tr("diagStatusOffline") }
    public static var diagLegendNormal: String { tr("diagLegendNormal") }
    public static var diagLegendAttention: String { tr("diagLegendAttention") }
    public static var diagLegendProblem: String { tr("diagLegendProblem") }
    public static var diagLegendNoData: String { tr("diagLegendNoData") }
    public static var diagConnHomeTheater: String { tr("diagConnHomeTheater") }
    public static var diagGroupByRoom: String { tr("diagGroupByRoom") }
    public static var supportProject: String { tr("supportProject") }
    public static var supportOnKofi: String { tr("supportOnKofi") }
    public static var supportSheetTitle: String { tr("supportSheetTitle") }
    public static var supportBlurb: String { tr("supportBlurb") }
    public static var bitcoin: String { tr("bitcoin") }
    public static var copyBitcoinAddress: String { tr("copyBitcoinAddress") }
    public static var diagTileOnline: String { tr("diagTileOnline") }
    public static var diagTileGoodLink: String { tr("diagTileGoodLink") }
    public static var diagTileAlerts: String { tr("diagTileAlerts") }
    public static var diagTileMedianLatency: String { tr("diagTileMedianLatency") }
    public static var diagNetworkColumnConnection: String { tr("diagNetworkColumnConnection") }
    public static var diagNetworkColumnLatency: String { tr("diagNetworkColumnLatency") }
    public static var diagNetworkColumnNoise: String { tr("diagNetworkColumnNoise") }
    public static var diagNetworkColumnPhyErrors: String { tr("diagNetworkColumnPhyErrors") }
    public static var diagNetworkUnreachable: String { tr("diagNetworkUnreachable") }
    public static func diagNetworkUpdatedFormat(_ time: String) -> String {
        String(format: tr("diagNetworkUpdatedFormat"), time)
    }
    public static func diagNetworkHealthReachableFormat(_ reachable: Int, _ total: Int) -> String {
        String(format: tr("diagNetworkHealthReachableFormat"), reachable, total)
    }
    public static func diagNetworkHealth24Format(_ count: Int) -> String {
        String(format: tr("diagNetworkHealth24Format"), count)
    }
    public static func diagNetworkHealthSlowFormat(_ count: Int) -> String {
        String(format: tr("diagNetworkHealthSlowFormat"), count)
    }
    public static var diagSpeakerColumnModel: String { tr("diagSpeakerColumnModel") }
    public static var diagSpeakerColumnIP: String { tr("diagSpeakerColumnIP") }
    public static var diagSpeakerColumnFirmware: String { tr("diagSpeakerColumnFirmware") }
    public static var diagSpeakerColumnRole: String { tr("diagSpeakerColumnRole") }
    public static var diagSpeakerColumnEvents: String { tr("diagSpeakerColumnEvents") }
    public static var diagSpeakerRoleMember: String { tr("diagSpeakerRoleMember") }
    public static var diagSpeakersEmpty: String { tr("diagSpeakersEmpty") }
    public static var diagSpeakerCallbackLabel: String { tr("diagSpeakerCallbackLabel") }
    public static func diagSpeakersCountFormat(_ count: Int) -> String {
        String(format: tr("diagSpeakersCountFormat"), count)
    }
    public static var liveEventsPause: String { tr("liveEventsPause") }
    public static var liveEventsResume: String { tr("liveEventsResume") }
    public static var liveEventsClear: String { tr("liveEventsClear") }
    public static var liveEventsLive: String { tr("liveEventsLive") }
    public static var liveEventsPausedNote: String { tr("liveEventsPausedNote") }
    public static var liveEventsSpeakerLabel: String { tr("liveEventsSpeakerLabel") }
    public static var liveEventsAllSpeakers: String { tr("liveEventsAllSpeakers") }
    public static var liveEventsResetFilters: String { tr("liveEventsResetFilters") }
    public static var liveEventsEmpty: String { tr("liveEventsEmpty") }
    public static func liveEventsCountFormat(_ shown: Int, _ total: Int) -> String {
        String(format: tr("liveEventsCountFormat"), shown, total)
    }
    public static func diagCopyRowsFormat(_ count: Int) -> String {
        String(format: tr("diagCopyRowsFormat"), count)
    }
    public static func diagEntriesCountFormat(_ filtered: Int, _ total: Int) -> String {
        String(format: tr("diagEntriesCountFormat"), filtered, total)
    }
    public static var speed: String { tr("speed") }
    public static var listeningRidges: String { tr("listeningRidges") }
    public static var albumConstellations: String { tr("albumConstellations") }
    public static var listeningFingerprint: String { tr("listeningFingerprint") }
    public static var daysConstellation: String { tr("daysConstellation") }
    public static var listeningClock: String { tr("listeningClock") }
    public static var listeningTrail: String { tr("listeningTrail") }
    public static var noAlbumsYet: String { tr("noAlbumsYet") }
    public static var noHistoryYet: String { tr("noHistoryYet") }
    public static var hour: String { tr("hour") }
    public static var artists: String { tr("artists") }

    // Plex Direct browse + auth flow
    public static var searchYourPlexLibraryPlaceholder: String { tr("searchYourPlexLibraryPlaceholder") }
    public static var nothingHere: String { tr("nothingHere") }
    public static var couldNotReachPlexServer: String { tr("couldNotReachPlexServer") }
    public static var plexPlaylists: String { tr("plexPlaylists") }
    public static var plexSmartPlaylist: String { tr("plexSmartPlaylist") }
    public static func plexTracksCount(_ n: Int) -> String { String(format: tr("plexTracksCountFormat"), n) }
    public static var connectsToPlexDirectlyDescription: String { tr("connectsToPlexDirectlyDescription") }
    public static var clickBelowToOpenPlex: String { tr("clickBelowToOpenPlex") }
    public static var waitingForPlexTvAuthorization: String { tr("waitingForPlexTvAuthorization") }
    public static var askingPlexTvForCode: String { tr("askingPlexTvForCode") }

    // Line-In browse
    public static var lineInSources: String { tr("lineInSources") }
    public static var noSpeakersWithLineInOrTV: String { tr("noSpeakersWithLineInOrTV") }

    // Lowercase "tracks" used as a unit suffix (e.g. "12 tracks")
    public static var tracksLowercase: String { tr("tracksLowercase") }

    // ForFunView visualisations — descriptions, loading states, axis labels
    public static func fullHistoryLoopsFormat(_ seconds: Int) -> String {
        String(format: tr("fullHistoryLoopsFormat"), seconds)
    }
    public static var listeningRidgesDescription: String { tr("listeningRidgesDescription") }
    public static var buildingRidges: String { tr("buildingRidges") }
    public static var discoveryComfortHeader: String { tr("discoveryComfortHeader") }
    public static var discoveryComfortDescription: String { tr("discoveryComfortDescription") }
    public static var needAtLeastFewWeeks: String { tr("needAtLeastFewWeeks") }
    public static var axisComfort: String { tr("axisComfort") }
    public static var axisDiscovery: String { tr("axisDiscovery") }
    public static var quadrantExploring: String { tr("quadrantExploring") }
    public static var quadrantComfortExploring: String { tr("quadrantComfortExploring") }
    public static var quadrantNostalgia: String { tr("quadrantNostalgia") }
    public static var quadrantScattered: String { tr("quadrantScattered") }
    public static var albumConstellationsDescription: String { tr("albumConstellationsDescription") }
    public static var buildingConstellations: String { tr("buildingConstellations") }
    public static var listeningFingerprintDescription: String { tr("listeningFingerprintDescription") }
    public static var buildingFingerprint: String { tr("buildingFingerprint") }
    public static var daysConstellationDescription: String { tr("daysConstellationDescription") }
    public static var dailyListeningHoursDescription: String { tr("dailyListeningHoursDescription") }
    public static var cumulativePlaysDescription: String { tr("cumulativePlaysDescription") }
    public static var topArtistsRoomsDescription: String { tr("topArtistsRoomsDescription") }
    public static var topArtistsByPlaysDescription: String { tr("topArtistsByPlaysDescription") }
    public static var waitingForData: String { tr("waitingForData") }
    public static var eachCellOneDayDescription: String { tr("eachCellOneDayDescription") }
    public static var timeSpiralsOutwardDescription: String { tr("timeSpiralsOutwardDescription") }
    public static var listeningClockDescription: String { tr("listeningClockDescription") }
    public static var axisLatest: String { tr("axisLatest") }
    public static var slimesDescription: String { tr("slimesDescription") }
    public static var poincareDescription: String { tr("poincareDescription") }
    public static var voronoiDescription: String { tr("voronoiDescription") }
    public static var arcsDescription: String { tr("arcsDescription") }
    public static var grayScottDescription: String { tr("grayScottDescription") }
    public static var seeding: String { tr("seeding") }
    public static var particleDriftDescription: String { tr("particleDriftDescription") }
    public static var mapperDescription: String { tr("mapperDescription") }
    public static var forceDirectedDescription: String { tr("forceDirectedDescription") }

    // Browse + history + Plex auth strings (third sweep)
    public static var recentlyPlayed: String { tr("recentlyPlayed") }
    public static var loadingCalmRadio: String { tr("loadingCalmRadio") }
    public static var loadingPlex: String { tr("loadingPlex") }
    public static var export: String { tr("export") }
    public static func deleteShownFormat(_ count: Int) -> String {
        String(format: tr("deleteShownFormat"), count)
    }
    public static var dateRangeTo: String { tr("dateRangeTo") }
    public static var signInWithPlex: String { tr("signInWithPlex") }

    // Apple Music sort picker
    public static var sortRelevance: String { tr("sortRelevance") }
    public static var sortNewest: String { tr("sortNewest") }
    public static var sortOldest: String { tr("sortOldest") }
    public static var sortTitle: String { tr("sortTitle") }
    public static var sortArtist: String { tr("sortArtist") }
    public static var sortTitleAscending: String { tr("sortTitleAscending") }
    public static var sortTitleDescending: String { tr("sortTitleDescending") }
    public static var sortArtistAscending: String { tr("sortArtistAscending") }
    public static var sortArtistDescending: String { tr("sortArtistDescending") }

    // MARK: - Lyrics settings (v4.0)
    public static var lyricsGlobalTimingOffset: String { tr("lyricsGlobalTimingOffset") }
    public static var lyricsGlobalOffsetHint: String { tr("lyricsGlobalOffsetHint") }
    public static var karaokeWindowTitle: String { tr("karaokeWindowTitle") }
    public static var karaokeTheme: String { tr("karaokeTheme") }
    public static func karaokeWindowTitleFormat(_ groupName: String) -> String {
        String(format: tr("karaokeWindowTitleFormat"), groupName)
    }

    // Club Vis popout (tiled poster wall, v3.x)
    public static var clubVis: String { tr("clubVis") }
    public static var clubVisWindowTitle: String { tr("clubVisWindowTitle") }
    public static var eventListenerPort: String { tr("eventListenerPort") }
    public static var eventListenerPortHint: String { tr("eventListenerPortHint") }
    public static var ssdpMulticastTTL: String { tr("ssdpMulticastTTL") }
    public static var ssdpMulticastTTLHint: String { tr("ssdpMulticastTTLHint") }
    public static var seedSpeakerAddresses: String { tr("seedSpeakerAddresses") }
    public static var seedSpeakerAddressesHint: String { tr("seedSpeakerAddressesHint") }
    public static var musicServers: String { tr("musicServers") }
    public static var sonosMusicServices: String { tr("sonosMusicServices") }
    public static var choragusSources: String { tr("choragusSources") }
    public static var playlistManager: String { tr("playlistManager") }
    public static var playlistBuilderService: String { tr("playlistBuilderService") }
    public static var playlistBuilderTitle: String { tr("playlistBuilderTitle") }
    public static var playlistBuilderIntro: String { tr("playlistBuilderIntro") }
    public static var playlistBuilderNamePlaceholder: String { tr("playlistBuilderNamePlaceholder") }
    public static func playlistBuilderMatchTo(_ service: String) -> String { String(format: tr("playlistBuilderMatchTo"), service) }
    public static func playlistBuilderProgress(_ done: Int, _ total: Int) -> String { String(format: tr("playlistBuilderProgress"), done, total) }
    public static func playlistBuilderSaved(_ name: String, _ count: Int) -> String { String(format: tr("playlistBuilderSaved"), name, count) }
    public static var playlistBuilderMisses: String { tr("playlistBuilderMisses") }
    public static func playlistBuilderParsedCount(_ n: Int) -> String { String(format: tr("playlistBuilderParsedCount"), n) }
    public static var playlistBuilderAIBriefPlaceholder: String { tr("playlistBuilderAIBriefPlaceholder") }
    public static var playlistBuilderGenerate: String { tr("playlistBuilderGenerate") }
    public static var playlistBuilderAIKeyPlaceholder: String { tr("playlistBuilderAIKeyPlaceholder") }
    public static var playlistBuilderAIModel: String { tr("playlistBuilderAIModel") }
    public static var playlistBuilderAIBaseURL: String { tr("playlistBuilderAIBaseURL") }
    public static var playlistBuilderAICustom: String { tr("playlistBuilderAICustom") }
    public static var playlistBuilderPaste: String { tr("playlistBuilderPaste") }
    public static var playlistBuilderNothingMatched: String { tr("playlistBuilderNothingMatched") }
    public static var playlistBuilderSaveFailed: String { tr("playlistBuilderSaveFailed") }
    public static var playlistBuilderClipboardEmpty: String { tr("playlistBuilderClipboardEmpty") }
    public static var playlistBuilderServiceFallback: String { tr("playlistBuilderServiceFallback") }
    public static var playlistBuilderGenerateWith: String { tr("playlistBuilderGenerateWith") }
    public static var playlistBuilderStop: String { tr("playlistBuilderStop") }
    public static var sortByName: String { tr("sortByName") }
    public static var playlistBuilderShowResponse: String { tr("playlistBuilderShowResponse") }
    public static var aiTab: String { tr("aiTab") }
    public static var aiPlaylistSection: String { tr("aiPlaylistSection") }
    public static var aiEnableService: String { tr("aiEnableService") }
    public static var aiSourceManual: String { tr("aiSourceManual") }
    public static var aiKeyStored: String { tr("aiKeyStored") }
    public static var aiKeySave: String { tr("aiKeySave") }
    public static var aiKeyClear: String { tr("aiKeyClear") }
    public static var aiTest: String { tr("aiTest") }
    public static var aiVerified: String { tr("aiVerified") }
    public static var aiSaveKeyFirst: String { tr("aiSaveKeyFirst") }
    public static var plexRemoteNote: String { tr("plexRemoteNote") }
    public static var aiAddService: String { tr("aiAddService") }
    public static var aiRemoveService: String { tr("aiRemoveService") }
    public static var aiNoServices: String { tr("aiNoServices") }
    public static var aiServiceNamePlaceholder: String { tr("aiServiceNamePlaceholder") }
    public static var aiNoServiceSelected: String { tr("aiNoServiceSelected") }
    public static var howDoesThisWork: String { tr("howDoesThisWork") }
    public static var helpAIPlaylists: String { tr("helpAIPlaylists") }
    public static var helpAIPlaylistsIntroBody: String { tr("helpAIPlaylistsIntroBody") }
    public static var helpAIPlaylistsAIHeading: String { tr("helpAIPlaylistsAIHeading") }
    public static var helpAIPlaylistsAIBody: String { tr("helpAIPlaylistsAIBody") }
    public static var helpAIPlaylistsManualHeading: String { tr("helpAIPlaylistsManualHeading") }
    public static var helpAIPlaylistsManualBody: String { tr("helpAIPlaylistsManualBody") }
    public static var helpAIPlaylistsSamplesHeading: String { tr("helpAIPlaylistsSamplesHeading") }
    public static var helpAIPlaylistsSampleBrief1: String { tr("helpAIPlaylistsSampleBrief1") }
    public static var helpAIPlaylistsSampleBrief2: String { tr("helpAIPlaylistsSampleBrief2") }
    public static var helpAIPlaylistsSampleBrief3: String { tr("helpAIPlaylistsSampleBrief3") }
    public static var helpAIPlaylistsFormatBody: String { tr("helpAIPlaylistsFormatBody") }
    public static func playlistBuilderAddedToQueue(_ count: Int, _ group: String) -> String { String(format: tr("playlistBuilderAddedToQueue"), count, group) }
    public static var playlistBuilderCopyPrompt: String { tr("playlistBuilderCopyPrompt") }
    public static var playlistBuilderPromptCopied: String { tr("playlistBuilderPromptCopied") }
    public static var sortByNewest: String { tr("sortByNewest") }
    public static var playlistBuilderSongsHeader: String { tr("playlistBuilderSongsHeader") }
    public static var playlistBuilderSaveHeader: String { tr("playlistBuilderSaveHeader") }
    public static var playlistBuilderGenerating: String { tr("playlistBuilderGenerating") }
    public static var mediaServersHeader: String { tr("mediaServersHeader") }
    public static var mediaServersEnableToggle: String { tr("mediaServersEnableToggle") }
    public static var mediaServersShowAll: String { tr("mediaServersShowAll") }
    public static var mediaServersManualOnly: String { tr("mediaServersManualOnly") }
    public static var mediaServersAddPlaceholder: String { tr("mediaServersAddPlaceholder") }
    public static var mediaServersTitlePlaceholder: String { tr("mediaServersTitlePlaceholder") }
    public static var playlistBuilderSendTo: String { tr("playlistBuilderSendTo") }
    public static var playlistBuilderDestinationPlaylist: String { tr("playlistBuilderDestinationPlaylist") }
    public static var mediaServersTitleLabel: String { tr("mediaServersTitleLabel") }
    public static var mediaServersAddLabel: String { tr("mediaServersAddLabel") }
    /// "Advertised as %@"
    public static func mediaServersAdvertisedAs(_ name: String) -> String { String(format: tr("mediaServersAdvertisedAsFormat"), name) }
    public static var mediaServersNoServerFound: String { tr("mediaServersNoServerFound") }
    public static var mediaServersExplainer: String { tr("mediaServersExplainer") }
    public static var mediaServersAllReachable: String { tr("mediaServersAllReachable") }
    public static var mediaServersCantReach: String { tr("mediaServersCantReach") }
    public static var mediaServersRecheck: String { tr("mediaServersRecheck") }
    public static var mediaServersChecking: String { tr("mediaServersChecking") }
    public static var mediaServersAdvertisedMismatch: String { tr("mediaServersAdvertisedMismatch") }
    public static var mediaServersNotChecked: String { tr("mediaServersNotChecked") }
    public static var mediaServersSpeakersOffline: String { tr("mediaServersSpeakersOffline") }
    public static var queueHealthScan: String { tr("queueHealthScan") }
    public static var queueHealthScanning: String { tr("queueHealthScanning") }
    public static var queueHealthAllOK: String { tr("queueHealthAllOK") }
    public static var queueHealthSummary: String { tr("queueHealthSummary") }
    public static var queueHealthRemoveBad: String { tr("queueHealthRemoveBad") }
    public static var queueHealthBadgeExpired: String { tr("queueHealthBadgeExpired") }
    public static var queueHealthBadgeDead: String { tr("queueHealthBadgeDead") }
    public static var queueHealthBadgeNoInfo: String { tr("queueHealthBadgeNoInfo") }
    public static var helpMediaServersHeading: String { tr("helpMediaServersHeading") }
    public static var helpMediaServersBody: String { tr("helpMediaServersBody") }
    public static var musicServersHint: String { tr("musicServersHint") }
    public static var addServerByAddress: String { tr("addServerByAddress") }
    public static var noMusicServersFound: String { tr("noMusicServersFound") }
    public static var removeAction: String { tr("removeAction") }
    public static var advancedNetwork: String { tr("advancedNetwork") }
    public static var galaxyVis: String { tr("galaxyVis") }
    public static var galaxyVisWindowTitle: String { tr("galaxyVisWindowTitle") }
    public static var galaxyLegend: String { tr("galaxyLegend") }
    public static var galaxyLegendDataField: String { tr("galaxyLegendDataField") }
    public static var galaxyLegendMarquee: String { tr("galaxyLegendMarquee") }
    public static var galaxyLegendMurmuration: String { tr("galaxyLegendMurmuration") }
    public static var galaxyLegendMycelium: String { tr("galaxyLegendMycelium") }
    public static var galaxyLegendTides: String { tr("galaxyLegendTides") }
    public static func clubVisWindowTitleFormat(_ groupName: String) -> String {
        String(format: tr("clubVisWindowTitleFormat"), groupName)
    }

    // MARK: - Software Updates (Sparkle, v4.x)
    public static var softwareUpdates: String { tr("softwareUpdates") }
    public static var autoCheckForUpdates: String { tr("autoCheckForUpdates") }
    public static var autoDownloadUpdates: String { tr("autoDownloadUpdates") }
    public static var neverChecked: String { tr("neverChecked") }
    public static func lastCheckedFormat(_ date: String) -> String {
        String(format: tr("lastCheckedFormat"), date)
    }

    // MARK: - Queue Library window (v4.x)
    public static var duplicate: String { tr("duplicate") }
    public static var newSubfolder: String { tr("newSubfolder") }
    public static var moveToMenu: String { tr("moveToMenu") }
    public static var topLevel: String { tr("topLevel") }
    public static var folders: String { tr("folders") }
    public static var removeFromAllFolders: String { tr("removeFromAllFolders") }
    public static var removeFromThisFolder: String { tr("removeFromThisFolder") }
    public static var newQueueEllipsis: String { tr("newQueueEllipsis") }
    public static var moveToTop: String { tr("moveToTop") }
    public static var moveToBottom: String { tr("moveToBottom") }
    public static var filterByRoomLabel: String { tr("filterByRoom") }
    public static var iconOrTableView: String { tr("iconOrTableView") }
    public static var listOrTableView: String { tr("listOrTableView") }
    public static var renameFolder: String { tr("renameFolder") }
    public static var folderName: String { tr("folderName") }
    public static var newFolder: String { tr("newFolder") }
    public static var exportM3U: String { tr("exportM3U") }
    public static var exportCSV: String { tr("exportCSV") }
    public static var dragToReorderQueueHint: String { tr("dragToReorderQueueHint") }
    public static var tapToAnimateArtwork: String { tr("tapToAnimateArtwork") }
    public static var animateArtworkRandomly: String { tr("animateArtworkRandomly") }

    // MARK: - Suno explore window (v4.11)
    public static var backToExplore: String { tr("backToExplore") }
    public static var noSpeakerSelected: String { tr("noSpeakerSelected") }
    public static var couldNotPlaySong: String { tr("couldNotPlaySong") }
    public static var loadingPlaylistEllipsis: String { tr("loadingPlaylistEllipsis") }
    public static var couldNotReadPlaylist: String { tr("couldNotReadPlaylist") }
    public static var openASongToPlay: String { tr("openASongToPlay") }
    public static var searchingAppleMusic: String { tr("searchingAppleMusic") }
    public static var pasteSunoLinkHint: String { tr("pasteSunoLinkHint") }
    public static func loadingSongsFormat(_ count: Int) -> String {
        String(format: tr("loadingSongsFormat"), count)
    }
    public static func playingSongsFormat(_ count: Int) -> String {
        String(format: tr("playingSongsFormat"), count)
    }
    public static func addedSongsFormat(_ count: Int) -> String {
        String(format: tr("addedSongsFormat"), count)
    }
    public static var playNowOnSonos: String { tr("playNowOnSonos") }
    public static var addToSonosQueue: String { tr("addToSonosQueue") }
    public static var playPlaylistOnSonos: String { tr("playPlaylistOnSonos") }
    public static var addPlaylistToSonosQueue: String { tr("addPlaylistToSonosQueue") }
    public static var playAllOnSonos: String { tr("playAllOnSonos") }
    public static var addAllToSonosQueue: String { tr("addAllToSonosQueue") }
    public static var couldNotPlayList: String { tr("couldNotPlayList") }

    // MARK: - Plex direct browse errors
    public static func nothingToPlayInFormat(_ title: String) -> String {
        String(format: tr("nothingToPlayInFormat"), title)
    }
    public static func couldNotPlayAllFormat(_ reason: String) -> String {
        String(format: tr("couldNotPlayAllFormat"), reason)
    }
    public static func plexDiscoveryFailedFormat(_ reason: String) -> String {
        String(format: tr("plexDiscoveryFailedFormat"), reason)
    }
    public static var directBrowseUnavailable: String { tr("directBrowseUnavailable") }
    public static var noSpeakerGroupSelected: String { tr("noSpeakerGroupSelected") }
    public static var trackNoPlayableMedia: String { tr("trackNoPlayableMedia") }
    public static func couldNotStartPlaybackFormat(_ reason: String) -> String {
        String(format: tr("couldNotStartPlaybackFormat"), reason)
    }
    public static func nothingToQueueFormat(_ title: String) -> String {
        String(format: tr("nothingToQueueFormat"), title)
    }
    public static func couldNotAddToQueueFormat(_ reason: String) -> String {
        String(format: tr("couldNotAddToQueueFormat"), reason)
    }
    public static var nothingToPlayInThisList: String { tr("nothingToPlayInThisList") }
    public static var nothingToAdd: String { tr("nothingToAdd") }
    public static func couldNotAddAllFormat(_ reason: String) -> String {
        String(format: tr("couldNotAddAllFormat"), reason)
    }

    // MARK: - Now Playing context panel history (v4.11)
    public static var thisTrack: String { tr("thisTrack") }
    public static var byThisArtist: String { tr("byThisArtist") }
    public static func uniqueTracksCountFormat(_ count: Int) -> String {
        String(format: tr("uniqueTracksCountFormat"), count)
    }

    // MARK: - Preset manager status
    public static func appliedPresetFormat(_ name: String) -> String {
        String(format: tr("appliedPresetFormat"), name)
    }
    public static func savedPresetWithEQFormat(_ name: String, _ group: String) -> String {
        String(format: tr("savedPresetWithEQFormat"), name, group)
    }
    public static func savedPresetFormat(_ name: String, _ group: String) -> String {
        String(format: tr("savedPresetFormat"), name, group)
    }

    // MARK: - v5 help entries, hardcoded-string sweep, AI playlist errors
    public static var helpQueueSelectionHeading: String { tr("helpQueueSelectionHeading") }
    public static var helpQueueSelectionBody: String { tr("helpQueueSelectionBody") }
    public static var helpQueueRunningTimeBody: String { tr("helpQueueRunningTimeBody") }
    public static var helpQueueHealthHeading: String { tr("helpQueueHealthHeading") }
    public static var helpQueueHealthBody: String { tr("helpQueueHealthBody") }
    public static var helpBrowseSectionCardsBody: String { tr("helpBrowseSectionCardsBody") }
    public static var refreshQueue: String { tr("refreshQueue") }
    public static var newQueue: String { tr("newQueue") }
    public static func savedAsFormat(_ name: String) -> String {
        String(format: tr("savedAsFormat"), name)
    }
    public static func restoredSnapshotFormat(_ summary: String) -> String {
        String(format: tr("restoredSnapshotFormat"), summary)
    }
    public static func savedTracksToChoragusFormat(_ count: Int, _ name: String) -> String {
        String(format: tr("savedTracksToChoragusFormat"), count, name)
    }
    public static var noDuplicatesFound: String { tr("noDuplicatesFound") }
    public static func removedDuplicatesFormat(_ count: Int) -> String {
        String(format: tr("removedDuplicatesFormat"), count)
    }
    public static var musicService: String { tr("musicService") }
    public static func searchResultsTitleFormat(_ query: String) -> String {
        String(format: tr("searchResultsTitleFormat"), query)
    }
    public static func noPlayableTracksInFormat(_ title: String) -> String {
        String(format: tr("noPlayableTracksInFormat"), title)
    }
    public static func stillAddingToFormat(_ name: String) -> String {
        String(format: tr("stillAddingToFormat"), name)
    }
    public static func savedToChoragusAsFormat(_ name: String) -> String {
        String(format: tr("savedToChoragusAsFormat"), name)
    }
    public static var showAllTracks: String { tr("showAllTracks") }
    public static var showStarredOnly: String { tr("showStarredOnly") }
    public static var lineInTVInput: String { tr("lineInTVInput") }
    public static var lineInAnalogInput: String { tr("lineInAnalogInput") }
    public static func analogInputFromFormat(_ room: String) -> String {
        String(format: tr("analogInputFromFormat"), room)
    }
    public static func tvInputFromFormat(_ room: String) -> String {
        String(format: tr("tvInputFromFormat"), room)
    }
    public static var unnamedSpeaker: String { tr("unnamedSpeaker") }
    public static var sonosPlayerFallback: String { tr("sonosPlayerFallback") }
    public static var dragToFolderHint: String { tr("dragToFolderHint") }
    public static var trackHasNoPlayableURI: String { tr("trackHasNoPlayableURI") }
    public static var emptyFolder: String { tr("emptyFolder") }
    public static var deletedItems: String { tr("deletedItems") }
    public static var mcpSection: String { tr("mcpSection") }
    public static var mcpEnable: String { tr("mcpEnable") }
    public static var mcpEnableHelp: String { tr("mcpEnableHelp") }
    public static var mcpAllowLAN: String { tr("mcpAllowLAN") }
    public static var mcpAllowLANHelp: String { tr("mcpAllowLANHelp") }
    public static var mcpPort: String { tr("mcpPort") }
    public static var mcpEndpoint: String { tr("mcpEndpoint") }
    public static var mcpTokens: String { tr("mcpTokens") }
    public static var mcpNoTokens: String { tr("mcpNoTokens") }
    public static var mcpTokenNamePlaceholder: String { tr("mcpTokenNamePlaceholder") }
    public static var mcpAddToken: String { tr("mcpAddToken") }
    public static var mcpRevoke: String { tr("mcpRevoke") }
    public static func mcpTokenCreatedFormat(_ date: String) -> String {
        String(format: tr("mcpTokenCreatedFormat"), date)
    }
    public static func mcpTokenLastUsedFormat(_ date: String) -> String {
        String(format: tr("mcpTokenLastUsedFormat"), date)
    }
    public static var mcpPreventSleep: String { tr("mcpPreventSleep") }
    public static var mcpOpenAtLogin: String { tr("mcpOpenAtLogin") }
    public static var mcpStatusRunning: String { tr("mcpStatusRunning") }
    public static var mcpStatusStopped: String { tr("mcpStatusStopped") }
    public static func mcpStatusFailedFormat(_ reason: String) -> String {
        String(format: tr("mcpStatusFailedFormat"), reason)
    }
    public static var mcpSetupLink: String { tr("mcpSetupLink") }
    public static var alarmMusic: String { tr("alarmMusic") }
    public static var alarmSectionPlay: String { tr("alarmSectionPlay") }
    public static var alarmStopAfter: String { tr("alarmStopAfter") }
    public static var alarmChime: String { tr("alarmChime") }
    public static var alarmChoose: String { tr("alarmChoose") }
    public static var alarmNoLimit: String { tr("alarmNoLimit") }
    public static var alarmShuffle: String { tr("alarmShuffle") }
    public static var alarmOnceOnly: String { tr("alarmOnceOnly") }
    public static var alarmOn: String { tr("alarmOn") }
    public static var alarmSaveFailed: String { tr("alarmSaveFailed") }
    public static var alarmFavoritesEmpty: String { tr("alarmFavoritesEmpty") }
    public static var alarmDeleteAlarm: String { tr("alarmDeleteAlarm") }
    public static func alarmMinutesFormat(_ minutes: Int) -> String {
        String(format: tr("alarmMinutesFormat"), minutes)
    }
    public static var mcpScope: String { tr("mcpScope") }
    public static var mcpSkipConfirm: String { tr("mcpSkipConfirm") }
    public static var mcpShowInToolbar: String { tr("mcpShowInToolbar") }
    public static var mcpShowInToolbarHelp: String { tr("mcpShowInToolbarHelp") }
    public static var mcpSkipConfirmHelp: String { tr("mcpSkipConfirmHelp") }
    public static var mcpScopeReadOnly: String { tr("mcpScopeReadOnly") }
    public static var mcpScopeControl: String { tr("mcpScopeControl") }
    public static var mcpScopeManage: String { tr("mcpScopeManage") }
    public static var mcpScopeReadOnlyHelp: String { tr("mcpScopeReadOnlyHelp") }
    public static var mcpScopeControlHelp: String { tr("mcpScopeControlHelp") }
    public static var mcpScopeManageHelp: String { tr("mcpScopeManageHelp") }
    public static var mcpMaxVolume: String { tr("mcpMaxVolume") }
    public static var mcpMaxVolumeHelp: String { tr("mcpMaxVolumeHelp") }
    public static var mcpQuietHours: String { tr("mcpQuietHours") }
    public static var mcpQuietHoursHelp: String { tr("mcpQuietHoursHelp") }
    public static var mcpQuietFrom: String { tr("mcpQuietFrom") }
    public static var mcpQuietTo: String { tr("mcpQuietTo") }
    public static var mcpQuietVolume: String { tr("mcpQuietVolume") }
    public static var mcpActivity: String { tr("mcpActivity") }
    public static var mcpActivityEmpty: String { tr("mcpActivityEmpty") }
    public static var mcpActivityClear: String { tr("mcpActivityClear") }
    public static func mcpTokenCallsFormat(_ count: Int) -> String {
        String(format: tr("mcpTokenCallsFormat"), count)
    }
    public static func mcpLockedOutFormat(_ address: String, _ until: String) -> String {
        String(format: tr("mcpLockedOutFormat"), address, until)
    }
    public static var copy: String { tr("copy") }
    public static var helpMCPHeading: String { tr("helpMCPHeading") }
    public static var helpMCPBody: String { tr("helpMCPBody") }
    public static var helpMCPClientsBody: String { tr("helpMCPClientsBody") }
    public static var helpMCPSafetyBody: String { tr("helpMCPSafetyBody") }
    public static var helpMCPOtherClientsBody: String { tr("helpMCPOtherClientsBody") }
    public static var queueAddInProgress: String { tr("queueAddInProgress") }
    public static var checkNetwork: String { tr("checkNetwork") }
    public static var aiStreamError: String { tr("aiStreamError") }
    public static var aiEmptyResponse: String { tr("aiEmptyResponse") }
    public static func addingTracksFormat(_ count: Int) -> String {
        String(format: tr("addingTracksFormat"), count)
    }
    public static var smartQueuesLabel: String { tr("smartQueuesLabel") }
    public static var historyLabel: String { tr("historyLabel") }
    public static func addedItemToFormat(_ item: String, _ target: String) -> String {
        String(format: tr("addedItemToFormat"), item, target)
    }
    public static func playingItemOnFormat(_ item: String, _ room: String) -> String {
        String(format: tr("playingItemOnFormat"), item, room)
    }
    public static func duplicatedItemFormat(_ item: String) -> String {
        String(format: tr("duplicatedItemFormat"), item)
    }
    public static func copiedItemToFormat(_ item: String, _ target: String) -> String {
        String(format: tr("copiedItemToFormat"), item, target)
    }
    public static func movedItemToFormat(_ item: String, _ target: String) -> String {
        String(format: tr("movedItemToFormat"), item, target)
    }
    public static var restore: String { tr("restore") }
    public static var deletePermanently: String { tr("deletePermanently") }
    public static var emptyDeletedItems: String { tr("emptyDeletedItems") }
    public static func deletedItemsRetentionFormat(_ days: Int) -> String {
        String(format: tr("deletedItemsRetentionFormat"), days)
    }
    public static func emptyDeletedItemsConfirmFormat(_ count: Int) -> String {
        String(format: tr("emptyDeletedItemsConfirmFormat"), count)
    }
    public static var helpQueueLibraryDeletedBody: String { tr("helpQueueLibraryDeletedBody") }
    public static func queueFooterTrackOfFormat(_ track: Int, _ total: Int) -> String {
        String(format: tr("queueFooterTrackOfFormat"), track, total)
    }
    public static func queueFooterRemainingFormat(_ remaining: String, _ total: String) -> String {
        String(format: tr("queueFooterRemainingFormat"), remaining, total)
    }
    public static var aiModelsReload: String { tr("aiModelsReload") }
    public static var aiModelsNeedKey: String { tr("aiModelsNeedKey") }
    public static func aiModelsUnavailableFormat(_ reason: String) -> String {
        String(format: tr("aiModelsUnavailableFormat"), reason)
    }
    public static var errorAmazonTrackRefused: String { tr("errorAmazonTrackRefused") }
    public static func couldNotStartInputFormat(_ what: String, _ detail: String) -> String {
        String(format: tr("couldNotStartInputFormat"), what, detail)
    }
    public static func intentRoomNotFoundFormat(_ name: String) -> String {
        String(format: tr("intentRoomNotFoundFormat"), name)
    }
    public static func intentPresetNotFoundFormat(_ name: String) -> String {
        String(format: tr("intentPresetNotFoundFormat"), name)
    }
    public static func intentInputNotFoundFormat(_ name: String) -> String {
        String(format: tr("intentInputNotFoundFormat"), name)
    }
    public static var serviceNotInHousehold: String { tr("serviceNotInHousehold") }
    public static func serviceNumberFormat(_ id: Int) -> String {
        String(format: tr("serviceNumberFormat"), id)
    }
    public static var couldNotLocateDownloadsFolder: String { tr("couldNotLocateDownloadsFolder") }
    public static var choragusDiagnostics: String { tr("choragusDiagnostics") }
    public static func searchingServiceFormat(_ service: String) -> String {
        String(format: tr("searchingServiceFormat"), service)
    }
    public static func loadingServiceFormat(_ service: String) -> String {
        String(format: tr("loadingServiceFormat"), service)
    }
    public static var tracksTitle: String { tr("tracksTitle") }
    public static var albumsTitle: String { tr("albumsTitle") }
    public static var aiKeyNotConfigured: String { tr("aiKeyNotConfigured") }
    public static var aiEndpointInvalid: String { tr("aiEndpointInvalid") }
    public static var aiInsecureEndpoint: String { tr("aiInsecureEndpoint") }
    public static func aiServiceErrorFormat(_ code: Int, _ detail: String) -> String {
        String(format: tr("aiServiceErrorFormat"), code, detail)
    }
    public static var aiRequestDeclined: String { tr("aiRequestDeclined") }
    public static var aiResponseNotSongList: String { tr("aiResponseNotSongList") }

    // MARK: - Translation Lookup

    /// Translations live in `Resources/Localizable.xcstrings`, a String
    /// Catalog. Xcode compiles it into this package's resource bundle as one
    /// `Localizable.strings` table per language, and lookup goes through
    /// Foundation on those tables. `swift build` copies the catalog as is,
    /// so under the SwiftPM command line (`swift test`, CI) the catalog JSON
    /// is decoded directly instead. Either way lookup follows the in-app
    /// language setting rather than the system locale, then falls back to
    /// English, then to the key itself.
    private static let table: TranslationTable = {
        var bundles: [String: Bundle] = [:]
        for language in AppLanguage.allCases {
            if let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                bundles[language.rawValue] = bundle
            }
        }
        if !bundles.isEmpty { return .compiled(bundles) }
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data) else {
            return .compiled([:])
        }
        return .catalog(catalog.strings.mapValues { entry in
            entry.localizations.compactMapValues { $0.stringUnit?.value }
        })
    }()

    private enum TranslationTable {
        case compiled([String: Bundle])
        case catalog([String: [String: String]])

        func value(_ key: String, _ language: String) -> String? {
            switch self {
            case .compiled(let bundles):
                guard let value = bundles[language]?.localizedString(forKey: key, value: L10n.missingMarker, table: nil),
                      value != L10n.missingMarker else { return nil }
                return value
            case .catalog(let strings):
                return strings[key]?[language]
            }
        }
    }

    /// The parts of the `.xcstrings` schema this lookup reads.
    private struct StringCatalog: Decodable {
        struct Unit: Decodable { let value: String }
        struct Localization: Decodable { let stringUnit: Unit? }
        struct Entry: Decodable { let localizations: [String: Localization] }
        let strings: [String: Entry]
    }

    /// Sentinel `localizedString(forKey:value:table:)` returns for an absent
    /// key, so a translation that happens to equal its key still resolves.
    private static let missingMarker = "\u{0}missing"

    static func tr(_ key: String) -> String {
        let language = UserDefaults.standard.string(forKey: UDKey.appLanguage) ?? "en"
        return table.value(key, language) ?? table.value(key, "en") ?? key
    }

    // MARK: - Errors and status messages (v5.0)

    public static var errNoSonosSpeakerFound: String { tr("errNoSonosSpeakerFound") }
    public static var errAppNetworkUnavailable: String { tr("errAppNetworkUnavailable") }
    /// "Speaker "%@" was not found on the network."
    public static func errAppSpeakerNotFound(_ value: String) -> String { String(format: tr("errAppSpeakerNotFound"), value) }
    /// "%@ requires sign-in. Open the Sonos app to re-authenticate."
    public static func errAppServiceAuthRequired(_ value: String) -> String { String(format: tr("errAppServiceAuthRequired"), value) }
    /// "Playback failed: %@"
    public static func errAppPlaybackFailed(_ value: String) -> String { String(format: tr("errAppPlaybackFailed"), value) }
    /// "Cache error: %@"
    public static func errAppCacheFailed(_ value: String) -> String { String(format: tr("errAppCacheFailed"), value) }
    public static var errAppTimeout: String { tr("errAppTimeout") }
    public static var errAppUnknown: String { tr("errAppUnknown") }
    public static var errSoapInvalidAction: String { tr("errSoapInvalidAction") }
    public static var errSoapItemNotFound: String { tr("errSoapItemNotFound") }
    public static var errSoapCannotTransition: String { tr("errSoapCannotTransition") }
    public static var errSoapNotSupportedInState: String { tr("errSoapNotSupportedInState") }
    public static var errSoapQueueFull: String { tr("errSoapQueueFull") }
    public static var errSoapInvalidSeek: String { tr("errSoapInvalidSeek") }
    public static var errSoapAuthRequired: String { tr("errSoapAuthRequired") }
    public static var errSoapUnexpectedResponse: String { tr("errSoapUnexpectedResponse") }
    public static var errSoapServiceError: String { tr("errSoapServiceError") }
    /// "Speaker returned an error (code %@)."
    public static func errSoapGenericCode(_ value: String) -> String { String(format: tr("errSoapGenericCode"), value) }
    public static var errMusicServiceGeneric: String { tr("errMusicServiceGeneric") }
    /// "%@ is not responding. Your network layout may have changed — refreshing now."
    public static func errStaleDeviceUnreachable(_ value: String) -> String { String(format: tr("errStaleDeviceUnreachable"), value) }
    /// "%@ group has changed. Refreshing speaker list."
    public static func errStaleGroupChanged(_ value: String) -> String { String(format: tr("errStaleGroupChanged"), value) }
    public static var errStaleTopology: String { tr("errStaleTopology") }
    public static var errStaleServiceRejected: String { tr("errStaleServiceRejected") }
    public static var errStaleNotPlayable: String { tr("errStaleNotPlayable") }
    public static var errStaleServiceUnavailable: String { tr("errStaleServiceUnavailable") }
    public static var errStaleNothingLoaded: String { tr("errStaleNothingLoaded") }
    /// "This music isn't set up on the selected system. Add your music folders in %@, then try again."
    public static func errStaleLibraryNotConfigured(_ value: String) -> String { String(format: tr("errStaleLibraryNotConfigured"), value) }
    public static var errStaleLibraryAppThisSystem: String { tr("errStaleLibraryAppThisSystem") }
    /// "the Sonos %@ app"
    public static func errStaleLibraryAppNamed(_ value: String) -> String { String(format: tr("errStaleLibraryAppNamed"), value) }
    public static var staleReconnecting: String { tr("staleReconnecting") }
    /// "%@ is not responding. Refreshing speakers..."
    public static func staleRoomNotResponding(_ value: String) -> String { String(format: tr("staleRoomNotResponding"), value) }
    public static var staleLayoutChanged: String { tr("staleLayoutChanged") }
    public static var smartQueueMostPlayed: String { tr("smartQueueMostPlayed") }
    public static var errPlexNotConnected: String { tr("errPlexNotConnected") }
    public static var errPlexNoServers: String { tr("errPlexNoServers") }
    /// "Network error: %@"
    public static func errPlexNetworkError(_ value: String) -> String { String(format: tr("errPlexNetworkError"), value) }
    /// "Plex returned HTTP %d."
    public static func errPlexHTTP(_ value: Int) -> String { String(format: tr("errPlexHTTP"), value) }
    /// "Couldn't parse Plex response: %@"
    public static func errPlexParse(_ value: String) -> String { String(format: tr("errPlexParse"), value) }
    public static var errPlexPinExpired: String { tr("errPlexPinExpired") }
    public static var plexWaitingForLink: String { tr("plexWaitingForLink") }
    public static var errPlexLinkTimedOut: String { tr("errPlexLinkTimedOut") }
    public static var errSMAPIDeviceIdentity: String { tr("errSMAPIDeviceIdentity") }
    public static var errSMAPIAuthTimedOut: String { tr("errSMAPIAuthTimedOut") }
    public static var errSMAPIInvalidURL: String { tr("errSMAPIInvalidURL") }
    /// "Service error: %@"
    public static func errSMAPIServiceError(_ value: String) -> String { String(format: tr("errSMAPIServiceError"), value) }
    public static var errSMAPINotSignedIn: String { tr("errSMAPINotSignedIn") }
    /// "Authentication failed: %@"
    public static func errSMAPIAuthFailed(_ value: String) -> String { String(format: tr("errSMAPIAuthFailed"), value) }
    public static var errLastFMAuthTimedOut: String { tr("errLastFMAuthTimedOut") }
    public static var errLastFMNoCredentials: String { tr("errLastFMNoCredentials") }
    public static var errLastFMNotSignedIn: String { tr("errLastFMNotSignedIn") }
    public static var errLastFMInvalidURL: String { tr("errLastFMInvalidURL") }
    public static var errBugReportEnvelopeAssembly: String { tr("errBugReportEnvelopeAssembly") }
    public static var errBugReportBodyEncoding: String { tr("errBugReportBodyEncoding") }
    public static var errBugReportEnvelopeMalformed: String { tr("errBugReportEnvelopeMalformed") }
    public static var errBugReportBodyMalformed: String { tr("errBugReportBodyMalformed") }
    public static var errBugReportKeyMissing: String { tr("errBugReportKeyMissing") }
    public static var errBugReportKeyInvalid: String { tr("errBugReportKeyInvalid") }
    public static var errBugReportWrapFailed: String { tr("errBugReportWrapFailed") }
    public static var notAvailable: String { tr("notAvailable") }
}
