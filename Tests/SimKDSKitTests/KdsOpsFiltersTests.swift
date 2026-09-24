import Foundation
import Testing
@testable import SimKDSKit

/// Port of `KdsOpsFiltersTest.kt`. Station filtering exercises `stationId`
/// directly (the `KdsStationFilter` enum is gone, delta 4); diagnostics take
/// `hasCredentials` because secrets no longer sit on the settings struct.
@Suite("KdsOpsFilters")
struct KdsOpsFiltersTests {
    @Test func filtersByPosOnlineAndStation() {
        let tickets = [
            Fixtures.ticket("A-41", status: .new, source: .pos, station: .barHot),
            Fixtures.ticket("M-11", status: .new, source: .online, station: .barCold),
            Fixtures.ticket("K-07", status: .new, source: .pos, station: .kitchen),
        ]

        let onlyPos = KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(source: .pos))
        let onlyOnline = KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(source: .online))
        let onlyKitchen = KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "station_kitchen"))
        let onlineColdBar = KdsOpsFilters.apply(
            tickets, filters: KdsBoardFilters(source: .online, stationId: "station_bar_cold")
        )

        #expect(Fixtures.displayNumbers(onlyPos) == ["A-41", "K-07"])
        #expect(Fixtures.displayNumbers(onlyOnline) == ["M-11"])
        #expect(Fixtures.displayNumbers(onlyKitchen) == ["K-07"])
        #expect(Fixtures.displayNumbers(onlineColdBar) == ["M-11"])
    }

    @Test func sourceFilterLabelsAreOperatorFacingAndUnknownSourceIsOnlyInAll() {
        let tickets = [
            Fixtures.ticket("IN-8F3K", status: .new, source: .pos),
            Fixtures.ticket("APP-5Q2M", status: .new, source: .online),
            Fixtures.ticket("UNK-1", status: .new, source: .unknown),
        ]

        #expect(KdsSourceFilter.all.operatorLabel == "Все")
        #expect(KdsSourceFilter.pos.operatorLabel == "За баром")
        #expect(KdsSourceFilter.online.operatorLabel == "Приложение")
        #expect(KdsTicketSource.unknown.operatorLabel == "Источник не указан")
        #expect(
            Fixtures.displayNumbers(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(source: .all)))
                == ["IN-8F3K", "APP-5Q2M", "UNK-1"]
        )
        #expect(
            Fixtures.displayNumbers(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(source: .pos)))
                == ["IN-8F3K"]
        )
        #expect(
            Fixtures.displayNumbers(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(source: .online)))
                == ["APP-5Q2M"]
        )
    }

    @Test func filtersConfiguredPostByStationId() {
        let tickets = [
            Fixtures.ticket("P-01", status: .new, station: KdsStation(stationId: "station_pastry", label: "PASTRY")),
            Fixtures.ticket("D-01", status: .new, station: KdsStation(stationId: "station_drinks", label: "DRINKS")),
        ]

        let pastry = KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "station_pastry"))

        #expect(Fixtures.displayNumbers(pastry) == ["P-01"])
    }

    @Test func filtersConfiguredPostByStationIdUsesExactStationIdMatch() {
        let tickets = [
            Fixtures.ticket("P-01", status: .new, station: KdsStation(stationId: "station_pastry", label: "PASTRY")),
            Fixtures.ticket("P-02", status: .new, station: KdsStation(stationId: "station_pastrylab", label: "PASTRYLAB")),
            Fixtures.ticket("P-03", status: .new, station: KdsStation(stationId: "station_pastry_lab", label: "PASTRY LAB")),
            Fixtures.ticket("B-01", status: .new, station: .barHot),
            Fixtures.ticket("B-02", status: .new, station: .barCold),
        ]

        let pastryLab = KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "station_pastry_lab"))

        #expect(Fixtures.displayNumbers(pastryLab) == ["P-03"])
    }

    @Test func malformedStationIdDoesNotMatchKnownPosts() {
        let tickets = [
            Fixtures.ticket("B-01", status: .new, station: KdsStation(stationId: "BAR", label: "BAR")),
            Fixtures.ticket("B-02", status: .new, station: KdsStation(stationId: "bar-hot", label: "BAR HOT MALFORMED")),
            Fixtures.ticket("B-03", status: .new, station: KdsStation(stationId: "bar_cold", label: "BAR COLD MALFORMED")),
        ]

        #expect(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "station_bar_hot")).isEmpty)
        #expect(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "station_bar_cold")).isEmpty)
    }

    @Test func malformedStationIdFilterDoesNotMatchCanonicalBarPosts() {
        let tickets = [
            Fixtures.ticket("B-01", status: .new, station: .barHot),
            Fixtures.ticket("B-02", status: .new, station: .barCold),
        ]

        #expect(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "bar-hot")).isEmpty)
        #expect(KdsOpsFilters.apply(tickets, filters: KdsBoardFilters(stationId: "bar_cold")).isEmpty)
    }

    @Test func classifiesWarningAndCriticalWaitTimes() {
        #expect(KdsWaitClassifier.classify(.seconds(4 * 60 + 59)) == .normal)
        #expect(KdsWaitClassifier.classify(.seconds(5 * 60)) == .warning)
        #expect(KdsWaitClassifier.classify(.seconds(10 * 60)) == .critical)
    }

    @Test func completedTicketsStayHiddenFromFilteredActiveBoard() {
        let active = Fixtures.ticket("A-41", status: .new, station: .barHot)
        let completed = Fixtures.ticket("A-42", status: .completed, station: .barHot)

        let board = KdsReducer.visibleBoard([completed, active])
        let filtered = KdsOpsFilters.apply(board.activeTickets, filters: KdsBoardFilters())

        #expect(Fixtures.displayNumbers(filtered) == ["A-41"])
    }

    // MARK: - Diagnostics & runtime validation (Kotlin kept them here too)

    @Test func diagnosticsNeverExposeCredentialMaterial() {
        // The settings struct carries no secrets at all — this pins the shape,
        // so a future field cannot quietly leak one into a label.
        let settings = KdsDeviceSettings(backendMode: .real)
        let auth = KdsDeviceDiagnostics.authLabel(hasCredentials: true)
        let status = KdsDeviceDiagnostics.baristaBackendStatus(
            settings: settings, hasCredentials: true
        )

        #expect(auth == "API key configured")
        #expect(!status.contains("password") && !status.contains("token"))
    }

    @Test func realBackendStatusRejectsRemoteCleartextUrl() {
        let settings = KdsDeviceSettings(
            apiBaseUrl: "http://192.168.1.20:8088",
            deviceId: "kds_ipad_bar_hot_01",
            actorId: "barista-17",
            backendMode: .real
        )

        #expect(KdsRuntimeContextValidation.requestError(settings) == "KDS Real API requires HTTPS")
        #expect(
            KdsDeviceDiagnostics.baristaBackendStatus(settings: settings, hasCredentials: true)
                == "Нужен HTTPS"
        )
        #expect(!KdsDeviceDiagnostics.isRealBackendActionReady(settings: settings, hasCredentials: true))
    }

    @Test func baristaBackendStatusIsHumanReadableAndSecretSafe() {
        let configured = KdsDeviceSettings(
            apiBaseUrl: "https://api.example.test",
            deviceId: "kds_ipad_bar_hot_01",
            actorId: "barista-17",
            backendMode: .real
        )
        var missingActor = configured
        missingActor.actorId = ""
        var placeholderDevice = configured
        placeholderDevice.deviceId = "device_placeholder"
        var mock = configured
        mock.backendMode = .mock

        #expect(
            KdsDeviceDiagnostics.baristaBackendStatus(settings: configured, hasCredentials: true)
                == "Real API готов"
        )
        #expect(
            KdsDeviceDiagnostics.baristaBackendStatus(settings: configured, hasCredentials: false)
                == "Нужен API key"
        )
        #expect(KdsDeviceDiagnostics.baristaBackendStatus(settings: mock, hasCredentials: false) == "Demo mode")
        #expect(
            KdsDeviceDiagnostics.baristaBackendStatus(settings: missingActor, hasCredentials: true)
                == "Нужен actorId"
        )
        #expect(
            KdsDeviceDiagnostics.baristaBackendStatus(settings: placeholderDevice, hasCredentials: true)
                == "Нужен deviceId"
        )
        #expect(KdsDeviceDiagnostics.isRealBackendActionReady(settings: configured, hasCredentials: true))
        #expect(!KdsDeviceDiagnostics.isRealBackendActionReady(settings: missingActor, hasCredentials: true))
        #expect(!KdsDeviceDiagnostics.isRealBackendActionReady(settings: placeholderDevice, hasCredentials: true))
    }

    @Test func stationDisplayLabelFallsBackToStationIdForCustomPost() {
        let settings = KdsDeviceSettings(stationId: "station_pastry")
        #expect(settings.stationDisplayLabel == "PASTRY")
    }
}
