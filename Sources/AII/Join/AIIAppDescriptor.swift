//
//  AIIAppDescriptor.swift
//  AII
//
//  Created by Ritesh Pakala on 10/21/26.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: What an app adopts to be a lane of the index: its name, and how people read it.
//  IN:   The app's own type: `enum Notes: AIIAppDescriptor { static let app: AIIApp = "notes" }`.
//  OUT:  What AIIInstance registers on join: the name, the display name, the bundle id.
//  PIN:  The name is the lane. The first app to register it on a Mac owns its secret,
//        lane and display name there; choose one no other app uses.
//

import Foundation

public protocol AIIAppDescriptor {
    /// The lane's name: `^[a-z][a-z0-9]{1,31}$`, never `aii`.
    static var app: AIIApp { get }
    /// How people read it. Default: the name, capitalized.
    static var displayName: String { get }
    /// The app's bundle id, when it has one. Default: the main bundle's.
    static var bundleIdentifier: String? { get }
}

extension AIIAppDescriptor {
    public static var displayName: String { app.displayName }
    public static var bundleIdentifier: String? { Bundle.main.bundleIdentifier }
}
