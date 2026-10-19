import Foundation
import Security

/// Philips Hue's bridge root certificate ("C=NL, O=Philips Hue, CN=root-bridge", valid 2017–2038,
/// SHA-256 F0:BD:8E:65:09:E8:2F:77:4D:63:BC:00:9D:53:88:C9:69:FE:3D:CF:7D:6D:54:1D:63:51:B7:2B:89:8D:8A:CF).
/// Genuine bridges (firmware 1.38+) present a certificate signed by it, whose name is the bridge id.
/// Verified against a real bridge's certificate before embedding.
enum HueRootCA {
    private static let der = "MIICMjCCAdigAwIBAgIUO7FSLbaxikuXAljzVaurLXWmFw4wCgYIKoZIzj0EAwIwOTELMAkGA1UEBhMCTkwxFDASBgNVBAoMC1BoaWxpcHMgSHVlMRQwEgYDVQQDDAtyb290LWJyaWRnZTAiGA8yMDE3MDEwMTAwMDAwMFoYDzIwMzgwMTE5MDMxNDA3WjA5MQswCQYDVQQGEwJOTDEUMBIGA1UECgwLUGhpbGlwcyBIdWUxFDASBgNVBAMMC3Jvb3QtYnJpZGdlMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEjNw2tx2AplOf9x86aTdvEcL1FU65QDxziKvBpW9XXSIcibAeQiKxegpq8Exbr9v6LBnYbna2VcaK0G22jOKkTqOBuTCBtjAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBhjAdBgNVHQ4EFgQUZ2ONTFrDT6o8ItRnKfqWKnHFGmQwdAYDVR0jBG0wa4AUZ2ONTFrDT6o8ItRnKfqWKnHFGmShPaQ7MDkxCzAJBgNVBAYTAk5MMRQwEgYDVQQKDAtQaGlsaXBzIEh1ZTEUMBIGA1UEAwwLcm9vdC1icmlkZ2WCFDuxUi22sYpLlwJY81Wrqy11phcOMAoGCCqGSM49BAMCA0gAMEUCIEBYYEOsa07TH7E5MJnGw557lVkORgit2Rm1h3B2sFgDAiEA1Fj/C3AN5psFMjo0//mrQebo0eKd3aWRx+pQY08mk48="

    static let certificate: SecCertificate? = Data(base64Encoded: der)
        .flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }

    /// If `leaf` is signed by the Hue root, returns the bridge id it was issued to (lowercase).
    static func verifiedBridgeID(leaf: SecCertificate) -> String? {
        guard let root = certificate else { return nil }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return nil }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { return nil }
        return (SecCertificateCopySubjectSummary(leaf) as String?)?.lowercased()
    }
}
