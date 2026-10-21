// swift-tools-version: 6.2
// Created by Ritesh Pakala on 10/21/26.
// Copyright © 2026 Rao Studios LLC.
// WHAT: Notes, the smallest app on the Ambient Intelligence Index: a lane of its own, a record
//       type of its own, and every verb an app uses — join, remember, recall, ask, forget.
// OUT:  `swift run --package-path Examples/Notes` from the AII checkout.
// PIN:  It depends on this checkout by path so it always builds against the code beside it. A
//       shipped app depends on AII by URL, with the servers left out:
//         .package(url: "https://github.com/rao-studios/AII.git", branch: "main", traits: [])
import PackageDescription

let package = Package(
    name: "Notes",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../..", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "Notes",
            dependencies: [.product(name: "AII", package: "AII")]
        ),
    ]
)
