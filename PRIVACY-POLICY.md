# Privacy Policy

**Last updated:** July 18, 2026

## Introduction

Better Bahn ("Besser Bahn") is a free and open-source application that helps users find cheaper split-ticket options for Deutsche Bahn (German Railway) connections. This privacy policy explains how the app handles your data.

**Source Code:** [https://github.com/chukfinley/Besser-Bahn](https://github.com/chukfinley/Besser-Bahn)

## Data Collection

**Better Bahn does not collect, store, or transmit any personal data to external servers.** The app operates entirely on your device.

### What data the app processes locally

- **DB Links:** URLs from bahn.de that you paste into the app to analyze train connections
- **User preferences:** Your settings such as age, BahnCard type, and Deutschland-Ticket status
- **Optional background location:** If you explicitly enable the GPS journey companion, the app processes your device position locally during an active watched journey to warn before your stop, estimate possible unreported delays, and suggest alternatives after a possibly missed train or connection. The position is not sent to the developer or stored in a developer-operated service. Android shows a persistent notification while this is active, and the feature can be disabled in Settings at any time.
- **Optional motion/activity signal:** When the GPS journey companion is active, Android may supply a coarse physical-activity signal (e.g. still vs. moving) that the location service uses to sample position more efficiently and save battery. It is processed only on your device for that purpose, never sent anywhere, and is only relevant while the companion is enabled.

All this data is processed locally on your device and is never sent to any server operated by the developer.

### Network requests

The app makes direct requests from your device to `bahn.de` to retrieve train schedule and pricing information. These requests are made directly from your device to Deutsche Bahn's servers, simulating what a web browser would do. The developer has no access to these requests or any data exchanged.

**There is no central server or backend.** This design choice was made intentionally to:
1. Protect user privacy
2. Avoid centralized data collection
3. Distribute network load across individual users

## Data Storage

All user preferences and settings are stored locally on your device. The app does not use cloud storage, analytics services, or any form of remote data storage.

## Third-Party Services

Better Bahn does not integrate any:
- Analytics or tracking services
- Advertising networks
- Crash reporting services
- Social media SDKs

The only external communication is directly with `bahn.de` to fetch train and pricing data.

## Data Sharing

We do not share any data with third parties because we do not collect any data.

## Children's Privacy

Better Bahn does not knowingly collect any personal information from anyone, including children under 13 years of age.

## Open Source

Better Bahn is free and open-source software (FOSS). The complete source code is available on GitHub, allowing anyone to verify the app's behavior and privacy practices:

[https://github.com/chukfinley/Besser-Bahn](https://github.com/chukfinley/Besser-Bahn)

## Changes to This Privacy Policy

We may update this privacy policy from time to time. Any changes will be posted on this page and in the GitHub repository.

## Contact

If you have questions about this privacy policy or the app, please open an issue on GitHub:

[https://github.com/chukfinley/Besser-Bahn/issues](https://github.com/chukfinley/Besser-Bahn/issues)

## Summary

- No personal data collected
- No analytics or tracking
- No advertisements
- All processing happens locally on your device
- Network requests go directly to bahn.de, not to any developer-controlled server
- Fully open source and auditable
