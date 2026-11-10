"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");
const crypto = require("crypto");

function parseArgs(argv) {
    const result = {};
    for (let i = 2; i < argv.length; i += 2) {
        const key = argv[i];
        const value = argv[i + 1];
        if (!key || !key.startsWith("--") || value === undefined) {
            throw new Error(`Invalid argument near ${key || "<end>"}`);
        }
        result[key.slice(2)] = value;
    }
    return result;
}

function createSeededRandom(seed) {
    let state = Number(seed) >>> 0;
    if (state === 0) {
        state = 0x6d2b79f5;
    }
    return function random() {
        state += 0x6d2b79f5;
        let value = state;
        value = Math.imul(value ^ (value >>> 15), value | 1);
        value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
        return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
    };
}

function loadScript(repoPath, relativePath) {
    const fullPath = path.join(repoPath, relativePath);
    const source = fs.readFileSync(fullPath, "utf8");
    vm.runInThisContext(source, { filename: fullPath });
}

async function runSimulation(input) {
    return await new Promise((resolve, reject) => {
        let warnings = [];
        let settled = false;
        try {
            global.SIM.runStats(input, message => {
                if (settled || !message) {
                    return;
                }
                if (Array.isArray(message.warnings)) {
                    warnings = message.warnings;
                }
                if (Array.isArray(message.errors) && message.errors.length > 0) {
                    settled = true;
                    reject(new Error(JSON.stringify(message.errors)));
                    return;
                }
                if (message.result) {
                    settled = true;
                    resolve({
                        warnings,
                        progressTotal: message.progressTotal,
                        result: message.result,
                    });
                }
            });
        } catch (error) {
            settled = true;
            reject(error);
        }
    });
}

async function main() {
    const args = parseArgs(process.argv);
    if (!args.repo || (!args.input && !args.jobs) || !args.output) {
        throw new Error("Required arguments: --repo, --output, and either --input or --jobs");
    }
    // These state fields must be handled by the selected engine revision.
    const adapterSource = fs.readFileSync(path.join(args.repo, "js/simulator-ui/sim-interface.js"), "utf8");
    for (const field of ["HPInit", "fuelInit", "ammoInit", "proficiency"]) {
        if (!adapterSource.includes(field)) {
            throw new Error(`当前引擎版本未声明支持初始状态字段 ${field}；未生成概率。`);
        }
    }

    global.window = global;
    if (!global.location) {
        global.location = { search: "", hash: "" };
    }
    if (!global.document) {
        global.document = {
            getElementById: () => null,
            querySelector: () => null,
            querySelectorAll: () => [],
        };
    }
    const nativeFetch = global.fetch;
    global.fetch = async resource => {
        if (typeof resource === "string" && !/^[a-z]+:/i.test(resource)) {
            const filePath = path.join(args.repo, resource.replaceAll("/", path.sep));
            return {
                ok: fs.existsSync(filePath),
                json: async () => JSON.parse(fs.readFileSync(filePath, "utf8")),
                text: async () => fs.readFileSync(filePath, "utf8"),
            };
        }
        return nativeFetch(resource);
    };

    const scripts = [
        "js/kcSHIPDATA.js",
        "js/kcEQDATA.js",
        "js/kcMAPDATA.js",
        "js/kcEDGES.js",
        "js/kcENEMYCOMP.js",
        "js/shared.js",
        "js/kcships.js",
        "js/kcsim.js",
        "js/kcsimcombined.js",
        "js/simulator-ui/common.js",
        "js/simulator-ui/sim-interface.js",
    ];
    for (const script of scripts) {
        loadScript(args.repo, script);
    }
    if (global.SHELL_RANGE_WEIGHTS && global.SHELL_RANGE_WEIGHTS.init) {
        await global.SHELL_RANGE_WEIGHTS.init();
    }

    const originalLog = console.log;
    console.log = () => {};
    let output;
    try {
        if (args.jobs) {
            const jobs = JSON.parse(fs.readFileSync(args.jobs, "utf8"));
            const results = [];
            for (const job of jobs) {
                Math.random = createSeededRandom(job.seed ?? 1);
                global.SIM.resetStats();
                const inputBytes = fs.readFileSync(job.input);
                const input = JSON.parse(inputBytes.toString("utf8"));
                if (job.numSims) {
                    input.numSims = Number(job.numSims);
                }
                const simulation = await runSimulation(input);
                results.push({
                    id: job.id,
                    input: job.input,
                    inputDigest: crypto.createHash("sha256").update(inputBytes).digest("hex"),
                    seed: Number(job.seed ?? 1),
                    simulations: simulation.progressTotal,
                    warnings: simulation.warnings,
                    result: simulation.result,
                });
            }
            output = {
                schemaVersion: 1,
                kind: "KC3KaiHeadlessBatchResult",
                engine: "KC3Kai Sortie Simulator",
                results,
            };
        } else {
            Math.random = createSeededRandom(args.seed || 1);
            const inputBytes = fs.readFileSync(args.input);
            const input = JSON.parse(inputBytes.toString("utf8"));
            const simulation = await runSimulation(input);
            output = {
                schemaVersion: 1,
                kind: "KC3KaiHeadlessResult",
                engine: "KC3Kai Sortie Simulator",
                inputDigest: crypto.createHash("sha256").update(inputBytes).digest("hex"),
                seed: Number(args.seed || 1),
                simulations: simulation.progressTotal,
                warnings: simulation.warnings,
                result: simulation.result,
            };
        }
    } finally {
        console.log = originalLog;
    }

    fs.mkdirSync(path.dirname(args.output), { recursive: true });
    fs.writeFileSync(args.output, JSON.stringify(output, null, 2), "utf8");
}

main().catch(error => {
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exitCode = 1;
});
