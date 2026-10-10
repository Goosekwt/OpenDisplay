# OpenDisplay

<!-- impeccable:product-schema 1 -->

## Platform
adaptive

## Stack
Implementation choice: native Windows host (.NET) and native SwiftUI iPad app, built on the user's Mac mini. User directed us to proceed. Transport and video performance take priority over a custom visual identity.

## Users
Personal use by the owner of a Windows PC and iPad.

## Product Purpose
Turn the iPad into an extended Windows monitor, with USB as the normal connection and Wi-Fi also supported.

## Operating Context
The user usually connects a cable, opens the iPad app, and expects the session to connect automatically. A Mac mini is available over SSH through Claude Code for iPad builds.

## Capabilities and Constraints
Required: real extra display, USB and Wi-Fi, remembered pairing, reconnect on foregrounding, automatic display selection and sizing to the iPad, and temporary arrows on BOTH displays indicating their relative arrangement at connection. Normal use should require no display settings; optional controls belong under Advanced. The arrows are location indicators, not a controls drawer. The connected device reports iPad17,1 and iPadOS 26.6.1. Performance targets must not be represented as measured results.

## Brand Commitments
Working name OpenDisplay (implementation assumption). User wants familiar Duet-like behavior; native platform controls suit the task. No custom brand requested.

## Evidence on Hand
Windows has Duet's signed UMDF/IddCx display driver and Apple Devices installed. Read-only inspection is authorized. The open-source implementation will be authored independently; proprietary binaries are not project dependencies.

## Product Principles
Prefer a plugged-in cable. Remember the paired device. Show connection state honestly. Keep the display unobstructed. Treat the Windows display arrangement as the source of truth for edge arrows.
