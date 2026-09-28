import Foundation
import Testing
@testable import SimKDSKit

/// Port of `KdsProvisioningTest.kt`, adjusted for two deltas: secrets live in
/// the Keychain (so "keeps/clears secrets" becomes the `clearsStoredCredentials`
/// flag), and non-generic `contract=` values reject the link (delta 3) — the
/// Kotlin suite's `simcafe_alpha` happy path becomes a rejection case.
@Suite("KdsProvisioning")
struct KdsProvisioningTests {
    @Test func parsesProvisioningLinkForRealBackendWithoutSecrets() throws {
        let current = KdsDeviceSettings(
            apiBaseUrl: "https://old.example.test",
            locationId: "old-location",
            stationId: "station_kitchen",
            deviceName: "Old device",
            deviceId: "old-device",
            actorId: "old-actor",
            backendMode: .mock
        )

        let rawUrl = "simkds://provision?"
            + "api=https%3A%2F%2Fkds.example.test"
            + "&locationId=flos-main"
            + "&station=bar_hot"
            + "&stationId=station_bar_hot"
            + "&deviceName=Bar%20Tablet"
            + "&deviceId=tablet_bar_01"
            + "&actorId=barista_01"
            + "&contract=generic_kds"
        let outcome = try #require(KdsProvisioning.settings(from: rawUrl, into: current))

        #expect(outcome.settings.apiBaseUrl == "https://kds.example.test")
        #expect(outcome.settings.locationId == "flos-main")
        #expect(outcome.settings.stationId == "station_bar_hot")
        #expect(outcome.settings.deviceName == "Bar Tablet")
        #expect(outcome.settings.deviceId == "tablet_bar_01")
        #expect(outcome.settings.actorId == "barista_01")
        #expect(outcome.settings.backendMode == .real)
        #expect(outcome.clearsStoredCredentials)
    }

    @Test func rejectsProvisioningLinksThatCarrySecrets() {
        let current = KdsDeviceSettings(apiBaseUrl: "https://api.example.test")

        for rawUrl in [
            "simkds://provision?token=dev-token",
            "simkds://provision?apiKey=dev-token",
            "simkds://provision?Token=dev-token",
            "simkds://provision?bearerToken=dev-token",
            "simkds://provision?user=compat-user",
            "simkds://provision?password=compat-password",
            "simkds://provision?basicAuthUsername=compat-user",
            "simkds://provision?basicAuthPassword=compat-password",
        ] {
            #expect(KdsProvisioning.settings(from: rawUrl, into: current) == nil)
        }
    }

    @Test(.tags(.regression)) func rejectsSeparatorVariantsOfAuthKeys() {
        // `api_key` / `bearer_token` are the same words as `apiKey` /
        // `bearerToken` once separators are stripped (review r4099014937).
        let current = KdsDeviceSettings(apiBaseUrl: "https://api.example.test")
        for rawUrl in [
            "simkds://provision?api_key=dev-key",
            "simkds://provision?bearer_token=dev-token",
            "simkds://provision?Authorization=Bearer%20x",
            "simkds://provision?client-secret=s3cret",
        ] {
            #expect(KdsProvisioning.settings(from: rawUrl, into: current) == nil)
        }
    }

    @Test(.tags(.regression)) func stationOnlyLinkKeepsMockMode() {
        // A station choice is board-local; it must not flip a demo tablet to
        // a real backend it has no credentials for (review r4099014251).
        let outcome = KdsProvisioning.settings(
            from: "simkds://provision?station=bar_cold",
            into: KdsDeviceSettings(backendMode: .mock)
        )
        #expect(outcome?.settings.backendMode == .mock)
        #expect(outcome?.settings.stationId == "station_bar_cold")
    }

    @Test(.tags(.regression)) func deviceOnlyLinkKeepsMockMode() {
        let outcome = KdsProvisioning.settings(
            from: "simkds://provision?deviceId=kds_ipad_01&actorId=barista_01",
            into: KdsDeviceSettings(backendMode: .mock)
        )
        #expect(outcome?.settings.backendMode == .mock)
    }

    @Test(.tags(.regression)) func explicitModeParamStillSwitches() {
        let outcome = KdsProvisioning.settings(
            from: "simkds://provision?mode=real&api=https%3A%2F%2Fkds.example.test",
            into: KdsDeviceSettings(backendMode: .mock)
        )
        #expect(outcome?.settings.backendMode == .real)
    }

    @Test(.tags(.regression)) func conflictingStationParamsLabelFollowsStationId() {
        // `station` and `stationId` disagree → the id owns routing, so the
        // label derives from it too (review r4099014572).
        let outcome = KdsProvisioning.settings(
            from: "simkds://provision?station=pastry&stationId=station_drinks",
            into: KdsDeviceSettings(backendMode: .mock)
        )
        #expect(outcome?.settings.stationId == "station_drinks")
        #expect(outcome?.settings.stationLabel == "DRINKS")
    }

    @Test func rejectsNonGenericContractLinks() {
        // Android mapped these to SimCafeAlpha/LegacyShell; this build speaks
        // Generic only, so the link is rejected rather than half-applied.
        let current = KdsDeviceSettings()

        for rawUrl in [
            "simkds://provision?api=https%3A%2F%2Fapi.example.test&contract=simcafe_alpha",
            "simkds://provision?api=https%3A%2F%2Fapi.example.test&contract=legacy_shell",
            "simkds://provision?api=https%3A%2F%2Fapi.example.test&contract=legacy",
        ] {
            #expect(KdsProvisioning.settings(from: rawUrl, into: current) == nil)
        }
    }

    @Test func keepsCurrentCredentialsForStationOnlyProvisioning() throws {
        let current = KdsDeviceSettings(
            apiBaseUrl: "https://api.example.test",
            locationId: "cafe_main",
            stationId: "station_bar_hot",
            deviceName: "Existing BAR-HOT",
            deviceId: "existing-bar-hot",
            actorId: "barista-17",
            backendMode: .real
        )

        let outcome = try #require(KdsProvisioning.settings(
            from: "simkds://provision?station=bar_cold&stationId=station_bar_cold",
            into: current
        ))

        #expect(outcome.settings.apiBaseUrl == "https://api.example.test")
        #expect(outcome.settings.stationId == "station_bar_cold")
        #expect(outcome.settings.deviceId == "existing-bar-hot")
        #expect(!outcome.clearsStoredCredentials)
    }

    @Test func flagsCredentialResetWhenProvisioningChangesBackendTarget() throws {
        let current = KdsDeviceSettings(
            apiBaseUrl: "https://old.example.test",
            locationId: "old-location",
            backendMode: .real
        )

        let rawUrl = "simkds://provision?"
            + "api=https%3A%2F%2Fkds.example.test"
            + "&locationId=flos-main"
            + "&station=bar_hot&stationId=station_bar_hot"
            + "&deviceName=Bar%20Tablet&deviceId=tablet_bar_01&actorId=barista_01"
        let outcome = try #require(KdsProvisioning.settings(from: rawUrl, into: current))

        #expect(outcome.settings.apiBaseUrl == "https://kds.example.test")
        #expect(outcome.settings.locationId == "flos-main")
        #expect(outcome.settings.backendMode == .real)
        #expect(outcome.clearsStoredCredentials)
    }

    @Test func missingActorIdDoesNotInventRuntimeActorForRealProvisioning() throws {
        let rawUrl = "simkds://provision?api=https%3A%2F%2Fkds.example.test"
            + "&station=bar_cold&deviceId=kds_ipad_bar_cold_01"
        let outcome = try #require(KdsProvisioning.settings(from: rawUrl, into: KdsDeviceSettings()))

        #expect(outcome.settings.actorId == "")
        #expect(outcome.settings.backendMode == .real)
        #expect(
            KdsRuntimeContextValidation.actionError(outcome.settings)
                == "KDS actorId is required before GenericKds action"
        )
    }

    @Test func placeholderActorIdFromProvisioningDoesNotBecomeRuntimeActor() throws {
        let rawUrl = "simkds://provision?api=https%3A%2F%2Fkds.example.test"
            + "&station=bar_hot&deviceId=kds_ipad_bar_hot_01&actorId=barista-kds"
        let outcome = try #require(KdsProvisioning.settings(from: rawUrl, into: KdsDeviceSettings(actorId: "")))

        #expect(outcome.settings.actorId == "")
        #expect(
            KdsRuntimeContextValidation.actionError(outcome.settings)
                == "KDS actorId is required before GenericKds action"
        )
    }

    @Test func authOnlyProvisioningIsRejected() {
        #expect(
            KdsProvisioning.settings(
                from: "simkds://provision?password=secret-password",
                into: KdsDeviceSettings(backendMode: .mock)
            ) == nil
        )
    }

    @Test func stationWithoutStationIdKeepsStationIdInSync() throws {
        let outcome = try #require(KdsProvisioning.settings(
            from: "simkds://provision?station=bar_cold",
            into: KdsDeviceSettings(stationId: "station_bar_hot")
        ))

        #expect(outcome.settings.stationId == "station_bar_cold")
    }

    @Test func unknownStationTokenUsesStationLabelFallback() throws {
        let rawUrl = "simkds://provision?station=pastry&stationId=station_pastry"
            + "&api=https%3A%2F%2Fkds.example.test"
        let outcome = try #require(KdsProvisioning.settings(
            from: rawUrl, into: KdsDeviceSettings(stationId: "station_bar_hot")
        ))

        #expect(outcome.settings.stationId == "station_pastry")
        #expect(outcome.settings.stationLabel == "PASTRY")
        #expect(outcome.settings.apiBaseUrl == "https://kds.example.test")
    }

    @Test func unknownStationTokenDerivesStationIdWhenStationIdIsMissing() throws {
        let outcome = try #require(KdsProvisioning.settings(
            from: "simkds://provision?station=pastry",
            into: KdsDeviceSettings(stationId: "station_bar_hot")
        ))

        #expect(outcome.settings.stationId == "station_pastry")
        #expect(outcome.settings.stationLabel == "PASTRY")
    }

    @Test func stationIdOnlyProvisioningDerivesKnownStationAndKeepsCustomLabel() throws {
        let known = try #require(KdsProvisioning.settings(
            from: "simkds://provision?stationId=station_bar_cold",
            into: KdsDeviceSettings(stationId: "station_bar_hot")
        ))
        let custom = try #require(KdsProvisioning.settings(
            from: "simkds://provision?stationId=station_pastry",
            into: KdsDeviceSettings(stationId: "station_pastry", stationLabel: "PASTRY")
        ))

        #expect(known.settings.stationId == "station_bar_cold")
        #expect(known.settings.stationLabel == "")
        #expect(custom.settings.stationId == "station_pastry")
        #expect(custom.settings.stationLabel == "PASTRY")
    }

    @Test func rejectsNonProvisioningLinks() {
        let current = KdsDeviceSettings()

        #expect(KdsProvisioning.settings(from: "https://api.example.test/provision", into: current) == nil)
        #expect(KdsProvisioning.settings(from: "simkds://wrong-host?password=secret", into: current) == nil)
        #expect(KdsProvisioning.settings(from: "not a url", into: current) == nil)
    }

    @Test func diagnosticsStaySecretSafeAfterProvisioning() throws {
        let outcome = try #require(KdsProvisioning.settings(
            from: "simkds://provision?station=bar_hot",
            into: KdsDeviceSettings(backendMode: .real)
        ))

        let label = KdsDeviceDiagnostics.authLabel(hasCredentials: true)
        #expect(label == "API key configured")
        #expect(!KdsDeviceDiagnostics.baristaBackendStatus(
            settings: outcome.settings, hasCredentials: true
        ).contains("password"))
    }
}
