# Spectra Privacy Policy

_Draft. Effective date: [DATE]. Last updated: 2026-06-21._

> This is a starting draft tailored to how Spectra works today. Have it reviewed
> before you publish, and keep it accurate as the app changes. Fill in every
> `[BRACKETED]` placeholder.

Spectra is built to keep your screen private. It processes what it captures on your
Mac and sends nothing about your screen anywhere. This policy explains the little data
that is involved and how it is handled. It applies to the Spectra macOS application
provided by [LEGAL NAME OR ENTITY] ("we", "us").

## The short version

- Your screen is processed entirely on your Mac. Spectra never records, stores, or
  uploads your screen contents.
- Spectra has no account, no analytics, and no telemetry.
- The only time Spectra talks to a server is to verify a license key you enter.
- Purchases are handled by Lemon Squeezy, our Merchant of Record. We never see your
  card details.

## Screen capture

To render effects across your desktop, Spectra uses the macOS Screen Recording
permission to capture your displays in real time. Captured frames are converted to GPU
textures, processed by the effect pipeline, and drawn back to the screen. Frames are
held in memory only for the moment they are processed and are then discarded. Spectra
does not write your screen to disk, does not keep a history of it, and does not
transmit it. Capture only runs while you have effects turned on.

## License validation

When you enter a license key to unlock the paid features, Spectra sends that key to
our licensing provider to check whether it is valid. The request contains the license
key and basic request metadata (such as your IP address, which any web request
includes). It does not contain your screen contents or any of your files. Spectra
stores your license key and the result of the last check locally on your Mac so it
keeps working offline. If you never enter a license key, Spectra makes no such
request.

## Purchases

Purchases and license issuance are handled by Lemon Squeezy, acting as the Merchant of
Record. When you buy Spectra, the payment and billing information you provide goes to
Lemon Squeezy and is governed by [Lemon Squeezy's privacy policy](https://www.lemonsqueezy.com/privacy).
We receive order and license information from Lemon Squeezy (such as your email and
license key) so we can support your purchase. We do not receive or store your full
payment-card details.

## Problem reports

The "Report a Problem" feature is manual and opt-in. When you use it, Spectra opens a
prefilled email in your mail app that includes the app version and basic system
information (your macOS version and Mac model), and it reveals the most recent Spectra
crash report in Finder so you can choose to attach it. Nothing is sent automatically;
you decide whether to send the email and what to attach. If you email us, we use that
information only to respond to and resolve your issue.

## Local data Spectra stores on your Mac

Spectra saves the following under `~/Library/Application Support/Spectra`, on your Mac
only: your settings, your per-display effect stacks and active presets, your saved
presets and composed effects, and your license record. This data stays on your device
and is never uploaded by Spectra. You can remove it by deleting that folder.

## Third parties

- **Lemon Squeezy** processes purchases and issues license keys (Merchant of Record).
- **Apple** provides macOS and the frameworks Spectra runs on.
- The optional Glass feature can install **yabai** through the **Homebrew** package
  manager. Those are run locally on your Mac at your choice and are governed by their
  own terms.

We do not use advertising networks, analytics SDKs, or third-party trackers.

## Your rights

Because Spectra collects no personal data through normal use, there is little for us to
hold. For any information you send us by email, or order information we receive from
Lemon Squeezy, you may contact us to ask what we hold, to correct it, or to delete it,
subject to applicable law (including the GDPR and CCPA where they apply). Lemon Squeezy
handles data-subject requests for the payment information it processes.

## Children

Spectra is not directed to children under 13 (or the minimum age in your country) and
we do not knowingly collect their personal data.

## Changes

We may update this policy as the app changes. We will update the effective date above,
and material changes will be described here.

## Contact

Privacy questions: jacksoswag@proton.me.
