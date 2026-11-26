import { describe, expect, it } from "vitest";
import { STATUS, boundsOf, clusters, projector, scaleBar, type Point } from "../src";

const at = (id: number, lat: number, lon: number, status: number = STATUS.open): Point => ({ id, lat, lon, status });

describe("the area shown", () => {
  it("holds every point, with room around them", () => {
    const b = boundsOf([at(1, 2800000, 7700000), at(2, 2900000, 7800000)])!;
    expect(b.minLat).toBeLessThan(2800000);
    expect(b.maxLon).toBeGreaterThan(7800000);
  });
  it("has a smallest size, so a single point is not magnified without limit", () => {
    const b = boundsOf([at(1, 2800000, 7700000)])!;
    expect(b.maxLat - b.minLat).toBeGreaterThanOrEqual(500);
    expect(b.maxLon - b.minLon).toBeGreaterThanOrEqual(500);
  });
  it("is nothing without points", () => expect(boundsOf([])).toBeNull());
});

describe("projection", () => {
  const bounds = { minLat: 5990000, maxLat: 6010000, minLon: -10000, maxLon: 10000 };   // around 60 degrees north
  const to = projector(bounds, 600, 400);
  it("puts north up and east right, inside the view", () => {
    const a = to(5990000, -10000), b = to(6010000, 10000);
    expect(b.x).toBeGreaterThan(a.x);
    expect(b.y).toBeLessThan(a.y);
    for (const p of [a, b]) { expect(p.x).toBeGreaterThanOrEqual(0); expect(p.x).toBeLessThanOrEqual(600); expect(p.y).toBeGreaterThanOrEqual(0); expect(p.y).toBeLessThanOrEqual(400); }
  });
  it("keeps distances equal in both directions", () => {
    const origin = to(6000000, 0);
    const north = to(6001000, 0), east = to(6000000, 2000);         // at 60 degrees a degree east is half a degree north
    expect((east.x - origin.x) / (origin.y - north.y)).toBeCloseTo(1, 2);
  });
});

describe("clustering", () => {
  const bounds = { minLat: 0, maxLat: 100000, minLon: 0, maxLon: 100000 };
  it("joins points that would overlap and keeps distant ones apart", () => {
    const found = clusters([at(1, 20000, 20000), at(2, 20100, 20100), at(3, 80000, 80000)], bounds, 600, 400, 48);
    expect(found.map((c) => c.ids.sort()).sort()).toEqual([[1, 2], [3]]);
  });
  it("shows the most urgent status of its members", () => {
    const [c] = clusters([at(1, 20000, 20000, STATUS.in_progress), at(2, 20000, 20000, STATUS.open), at(3, 20000, 20000, STATUS.acknowledged)], bounds, 600, 400, 48);
    expect(c!.status).toBe(STATUS.open);
    expect(c!.lead).toBe(2);
  });
  it("leaves out what is outside the view", () => {
    expect(clusters([at(1, 200000, 20000)], bounds, 600, 400, 48)).toEqual([]);
  });
  it("draws a bounded number of markers however many points there are", () => {
    const many = Array.from({ length: 20000 }, (_, i) => at(i + 1, (i * 7919) % 100000, (i * 104729) % 100000));
    const found = clusters(many, bounds, 600, 400, 48);
    expect(found.length).toBeLessThanOrEqual(Math.ceil(600 / 48 + 1) * Math.ceil(400 / 48 + 1));
    expect(found.reduce((n, c) => n + c.ids.length, 0)).toBe(20000);
  });
});

describe("the scale bar", () => {
  it("shows a round distance that fits", () => {
    const bar = scaleBar({ minLat: 0, maxLat: 100000, minLon: 0, maxLon: 100000 }, 600, 400);   // 1 degree: about 111 km
    expect([1, 2, 5, 10, 20, 50]).toContain(bar.meters / 1000);
    expect(bar.pixels).toBeGreaterThan(30);
    expect(bar.pixels).toBeLessThanOrEqual(150);
  });
});
