// tthermal-week summary: the week lines in the status file, from a made-up desk-fanlog CSV.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const bin = join(dirname(fileURLToPath(import.meta.url)), "..", "desk", "bin", "tthermal-week");
const head =
  "time,tdie,cpu_core_w,cpu_soc_w,load1,b_t1,b_t2,b_t3,b_t4,b_t5,b_t6,fan1_cpu,fan2_sys1_top,fan3_sys2_intake,fan4_pch," +
  "fan5_cpuopt_rear,gpu_c,gpu_w,gpu_pstate,gpu_util,gpu_fan,nvme_c,dimm1_c,dimm2_c";
const pad = (n) => String(n).padStart(2, "0");
const local = (d) =>
  `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;

// rows: [cpu, gpu, gpu_util, top rpm, chipset rpm], 30 s apart from 20 min ago, each in its own day's file
function summary(rows, gapAfter = -1) {
  const dir = mkdtempSync(join(tmpdir(), "tthermal-week-"));
  try {
    const t0 = Date.now() - 20 * 60_000;
    const days = {};
    rows.forEach(([cpu, gpu, util, top, pch], i) => {
      const t = local(new Date(t0 + i * 30_000 + (gapAfter >= 0 && i > gapAfter ? 600_000 : 0)));
      (days[t.slice(0, 10)] ??= [head]).push(`${t},${cpu},20,8,0.2,24,27,46,26,46,42,600,${top},530,${pch},600,${gpu},20,P8,${util},0,35,32,32`);
    });
    for (const [day, lines] of Object.entries(days)) writeFileSync(join(dir, `${day}.csv`), lines.join("\n") + "\n");
    const out = execFileSync(bin, ["summary"], { env: { ...process.env, DESK_FANLOG_DIR: dir } }).toString();
    return Object.fromEntries(out.trim().split("\n").map((l) => l.split("=")).map(([k, v]) => [k, Number(v)]));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("max temperatures and gaming minutes (GPU at 50 % or more, 30 s a sample)", () => {
  const rows = [[50, 40, 2, 400, 0], [77, 70, 80, 400, 0], [60, 65, 50, 400, 0], [55, 60, 49, 400, 0]];
  assert.deepEqual(summary(rows), { week_cpu_max: 77, week_gpu_max: 70, week_gaming_min: 1, week_fan_stops: 0 });
});

test("a fan stop is 0 rpm in 3 samples in a row; the chipset fan doesn't count", () => {
  const rows = [[50, 40, 0, 400, 0], [50, 40, 0, 0, 0], [50, 40, 0, 0, 0], [50, 40, 0, 0, 0], [50, 40, 0, 0, 0], [50, 40, 0, 400, 0]];
  assert.equal(summary(rows).week_fan_stops, 1);
  assert.equal(summary(rows.slice(0, 3)).week_fan_stops, 0);
});

test("a gap (the desk asleep) breaks a run of zeros", () => {
  const rows = [[50, 40, 0, 0, 0], [50, 40, 0, 0, 0], [50, 40, 0, 0, 0], [50, 40, 0, 0, 0]];
  assert.equal(summary(rows, 1).week_fan_stops, 0);
});

test("no log prints nothing", () => {
  const dir = mkdtempSync(join(tmpdir(), "tthermal-week-"));
  const out = execFileSync(bin, ["summary"], { env: { ...process.env, DESK_FANLOG_DIR: dir } }).toString();
  rmSync(dir, { recursive: true, force: true });
  assert.equal(out, "");
});
