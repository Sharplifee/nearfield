#!/usr/bin/env swift
// Converts the Bluetooth SIG public assigned-numbers YAML into the compact JSON the app loads.
// Clone first:
//   git clone https://bitbucket.org/bluetooth-SIG/public.git sig-public
// Then:
//   swift Scripts/build-sig-catalog.swift sig-public/assigned_numbers Resources
//
// Produces: companies.json  (hex string -> name, 0000 EXCLUDED)
//           services.json   (16-bit hex -> name)
//           characteristics.json (16-bit hex -> {name, description})
//
// Re-run on every SIG release. This is public spec data and is NOT the moat —
// the moat is Resources/apple-models.json, which you maintain by hand.
import Foundation
print("Stub — implement YAML parse or use yq. Exclude company 0x0000 from the output.")
