import Foundation
import Security
import DoubaoVoiceHelperCore

enum UpdateVerificationError: LocalizedError {
    case bundleIdentifierMismatch
    case notNewer(String)
    case currentSignatureUnverifiable
    case signatureInvalid(OSStatus)

    var errorDescription: String? {
        switch self {
        case .bundleIdentifierMismatch:
            return "更新包的应用标识与当前应用不一致，已拒绝安装"
        case .notNewer(let version):
            return "更新包版本 \(version) 不高于当前版本，已拒绝安装"
        case .currentSignatureUnverifiable:
            return "当前应用使用临时签名，无法校验更新包，请前往 GitHub 手动下载"
        case .signatureInvalid(let status):
            return "更新包签名校验失败（\(status)），已拒绝安装"
        }
    }
}

/// An update is installed only if it satisfies the running app's designated
/// requirement, i.e. it was signed by the same certificate or team. This is
/// what makes it acceptable to clear the quarantine flag afterwards.
enum UpdateVerifier {
    static func verify(stagedApp: URL, currentVersion: String) throws {
        guard let staged = Bundle(url: stagedApp),
              staged.bundleIdentifier == AppSettings.bundleIdentifier
        else {
            throw UpdateVerificationError.bundleIdentifierMismatch
        }

        let stagedVersion = staged.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard AppVersion(stagedVersion) > AppVersion(currentVersion) else {
            throw UpdateVerificationError.notNewer(stagedVersion)
        }

        let requirement = try currentDesignatedRequirement()

        var stagedCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(stagedApp as CFURL, [], &stagedCode)
        guard createStatus == errSecSuccess, let stagedCode else {
            throw UpdateVerificationError.signatureInvalid(createStatus)
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
        )
        let status = SecStaticCodeCheckValidity(stagedCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateVerificationError.signatureInvalid(status)
        }
    }

    private static func currentDesignatedRequirement() throws -> SecRequirement {
        var selfCode: SecCode?
        var staticSelf: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticSelf) == errSecSuccess,
              let staticSelf,
              SecCodeCopyDesignatedRequirement(staticSelf, [], &requirement) == errSecSuccess,
              let requirement
        else {
            throw UpdateVerificationError.currentSignatureUnverifiable
        }

        // Ad-hoc signatures only pin the exact binary hash, which no new build
        // can satisfy, so there is no identity to compare against.
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
           let text,
           (text as String).hasPrefix("cdhash")
        {
            throw UpdateVerificationError.currentSignatureUnverifiable
        }
        return requirement
    }
}
