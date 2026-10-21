//
//  CodeSignature.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: Whether an app's bundled AIIServer may be run: signed by Rao's Developer
//        ID team, intact.
//  IN:   AIIInstaller (before copying a bundled build in, and before every exec of
//        an installed bundled build).
//  PIN:  ~/.rao is writable by anything running as this user, so a bundled build is
//        only run once its signature says Rao built it. The person's own build
//        (install.json `source: local`) is vouched for by its 0600 record instead
//        (AIIInstaller.verifyInstalled). Development builds of an app accept anything;
//        a shipped app never does.
//

#if os(macOS)
import Foundation
import Security

public enum SignaturePolicy: Sendable, Equatable {
    /// Valid, and signed by this Apple Developer team.
    case developerID(teamID: String)
    /// Development only: no check.
    case unchecked

    /// Rao's Apple Developer team.
    public static let teamID = "TA6WK7F4P8"

    /// Release builds check for Rao's team; debug builds don't.
    public static var standard: SignaturePolicy {
        #if DEBUG
        return .unchecked
        #else
        return .developerID(teamID: teamID)
        #endif
    }

    public var requirement: String? {
        switch self {
        case .developerID(let teamID):
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        case .unchecked:
            return nil
        }
    }

    /// Throws unless `url` satisfies the policy.
    public func check(_ url: URL) throws {
        guard let requirementText = requirement else { return }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw SignatureError.unreadable(url.path(percentEncoded: false), status)
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw SignatureError.unreadable(requirementText, status)
        }
        status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
        guard status == errSecSuccess else {
            throw SignatureError.rejected(url.path(percentEncoded: false), status)
        }
    }
}

public enum SignatureError: Error, Equatable, CustomStringConvertible {
    case unreadable(String, OSStatus)
    case rejected(String, OSStatus)

    public var description: String {
        switch self {
        case .unreadable(let what, let status): return "can't read the signature of \(what) (\(status))"
        case .rejected(let what, let status): return "\(what) is not signed by Rao (\(status))"
        }
    }
}
#endif
