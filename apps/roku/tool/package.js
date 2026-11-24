#!/usr/bin/env node
// Zips the channel for sideloading (out/zorofin-roku.zip). The signed .pkg
// for the Channel Store is made on a Roku in developer mode; see docs/RELEASE.md.
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const out = path.join(root, "out");
fs.mkdirSync(out, { recursive: true });
const zip = path.join(out, "zorofin-roku.zip");
fs.rmSync(zip, { force: true });
const entries = ["manifest", "source", "components", "images", "fonts"];
execFileSync("zip", ["-q", "-r", "-9", zip, ...entries, "-x", "*.DS_Store", "fonts/*.txt"], { cwd: root, stdio: "inherit" });
const size = fs.statSync(zip).size;
console.log(`${path.relative(process.cwd(), zip)} (${(size / 1024).toFixed(0)} KB)`);
