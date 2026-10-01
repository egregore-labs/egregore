#!/usr/bin/env node
"use strict";

// Keep the harness adapter thin; operation and branch checks live in bin/.
require("../../bin/branch-guard.cjs").main();
