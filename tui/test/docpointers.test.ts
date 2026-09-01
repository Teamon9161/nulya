import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Split around `+` so these lists do not match themselves: the scan covers
// every source file, this one included, and an exemption would be a hole in
// exactly the wrong place.
const POINTERS = ["tui" + ".md", "DESIGN" + " \u00a7", "PLAN" + " \u00a7", "BUGS" + " #", "docs/" + "goals"];

// A milestone tag from the implementation log resolves only inside that
// archived log. Whatever a comment needs from such an entry belongs in it as a fact.
const MILESTONE = /\bT\d{1,3}\b/;

function sources(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === "dist" || name.startsWith(".")) continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) sources(path, out);
    else if (/\.tsx?$/.test(name)) out.push(path);
  }
  return out;
}

// Only comment lines: a generic type parameter with a milestone-shaped name is not a pointer.
const isComment = (line: string) => /^\s*(\/\/|\/?\*)/.test(line);

test("no documentation pointers in shipped source", () => {
  const offenders: string[] = [];
  for (const path of sources(join(import.meta.dir, ".."))) {
    readFileSync(path, "utf8")
      .split("\n")
      .forEach((line, i) => {
        if (!isComment(line)) return;
        const hit = POINTERS.find((p) => line.includes(p)) ?? (MILESTONE.test(line) ? "T<n>" : null);
        if (hit) offenders.push(`${path.slice(path.indexOf("tui"))}:${i + 1}: ${hit}`);
      });
  }
  expect(offenders).toEqual([]);
});
