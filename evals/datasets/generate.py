#!/usr/bin/env python3
"""Generate the 10 sample datasets for the Spark evals (standard library only).

  python3 evals/datasets/generate.py                 # default size, writes next to this file
  python3 evals/datasets/generate.py --scale 10      # 10 times more rows
  python3 evals/datasets/generate.py --rows 200000   # exact number of rows in each big table
  python3 evals/datasets/generate.py --domain finance --out /tmp/data

The output is deterministic: the same --seed, --rows and --scale give the same files.
Each dataset has dirty rows on purpose (null values, bad dates, duplicates, out-of-range
numbers, messy text), so the Spark jobs have cleaning work to do.
"""
import argparse
import csv
import datetime as dt
import os
import random

DEFAULT_ROWS = 50000
START = dt.date(2023, 1, 1)
DAYS = 730  # 2023-01-01 .. 2024-12-30


class Gen:
    """Random helpers. Every dirty value comes from one seeded generator."""

    def __init__(self, seed):
        self.r = random.Random(seed)

    def day(self, lo=0, hi=DAYS - 1):
        return START + dt.timedelta(days=self.r.randint(lo, hi))

    def pick(self, items, weights=None):
        return self.r.choices(items, weights)[0]

    def skew(self, n):
        """Index 0..n-1 with a long tail (some items are much more common)."""
        return int((self.r.random() ** 2) * n)

    # ---- dirt: each helper returns the clean value most of the time ----
    def d_null(self, v, p=0.02):
        return self.r.choice(["", "NULL", "n/a"]) if self.r.random() < p else v

    def d_date(self, d, p=0.015):
        if self.r.random() < p:
            return self.r.choice(["", "N/A", "2024-13-45", "31/02/2024", "not-a-date", "0000-00-00"])
        return d.isoformat()

    def d_text(self, s, p=0.05):
        if self.r.random() < p:
            return self.r.choice([s.upper(), " " + s + " ", s.capitalize()])
        return s

    def d_dupes(self, rows, p=0.01):
        extra = [list(x) for x in self.r.sample(rows, int(len(rows) * p))]
        rows = rows + extra
        self.r.shuffle(rows)
        return rows


def ids(prefix, n, width):
    return [f"{prefix}{i:0{width}d}" for i in range(1, n + 1)]


# ------------------------------------------------------------------ domains
def finance(g, n):
    na = max(100, n // 50)
    acc_ids = ids("A", na, 5)
    accounts = [[a, g.pick(["retail", "business", "premium"], [70, 20, 10]),
                 g.pick(["MY", "SG", "ID", "TH", "VN"]), g.day(0, 400).isoformat()] for a in acc_ids]
    cats = ["groceries", "dining", "transport", "utilities", "travel", "entertainment", "health", "shopping"]
    rows = []
    for i in range(1, n + 1):
        acc = acc_ids[g.skew(na)] if g.r.random() > 0.005 else "A99999"  # a few orphan accounts
        amt = round(g.r.lognormvariate(3.5, 1.0), 2)
        if g.r.random() < 0.01:
            amt = -amt  # out-of-range value
        rows.append([f"T{i:08d}", acc, g.d_date(g.day()), g.d_null(f"{amt:.2f}"),
                     g.pick(["MYR", "USD", "SGD"], [80, 12, 8]), g.d_text(g.pick(cats)),
                     f"M{g.skew(200):03d}", g.pick(["posted", "pending", "reversed"], [90, 6, 4])])
    return {"accounts": (["account_id", "segment", "country", "opened_date"], accounts),
            "transactions": (["txn_id", "account_id", "txn_date", "amount", "currency", "category",
                              "merchant", "status"], g.d_dupes(rows))}


def logistics(g, n):
    carriers = [["C01", "SwiftFreight", "road"], ["C02", "AirBridge", "air"], ["C03", "BlueWave", "sea"],
                ["C04", "IronRail", "rail"], ["C05", "QuickHaul", "road"], ["C06", "SkyCargo", "air"]]
    cities = ["Kuala Lumpur", "Penang", "Johor Bahru", "Singapore", "Jakarta", "Bangkok", "Hanoi",
              "Manila", "Surabaya", "Ipoh", "Kuching", "Medan"]
    rows = []
    for i in range(1, n + 1):
        c = g.pick(carriers)
        o, d = g.r.sample(cities, 2)
        ship = g.day(0, DAYS - 20)
        base = {"road": 3, "air": 1, "sea": 9, "rail": 5}[c[2]]
        deliv = ship + dt.timedelta(days=max(0, int(g.r.gauss(base, 2))))
        if g.r.random() < 0.01:
            deliv = ship - dt.timedelta(days=g.r.randint(1, 5))  # delivered before shipped
        wt = round(g.r.lognormvariate(3.0, 0.9), 1)
        cost = round(wt * g.r.uniform(0.5, 3.0) + 10, 2)
        rows.append([f"S{i:08d}", c[0], o, d, g.d_date(ship), g.d_date(deliv, 0.03),
                     g.d_null(f"{wt:.1f}"), g.d_null(f"{cost:.2f}"),
                     g.pick(["delivered", "in_transit", "returned"], [92, 5, 3])])
    return {"carriers": (["carrier_id", "carrier_name", "mode"], carriers),
            "shipments": (["shipment_id", "carrier_id", "origin", "destination", "ship_date",
                           "delivery_date", "weight_kg", "cost", "status"], g.d_dupes(rows))}


def helpdesk(g, n):
    na = max(40, n // 400)
    agents = [[a, g.pick(["network", "desktop", "security", "cloud"]), g.pick(["L1", "L2", "L3"], [60, 30, 10])]
              for a in ids("AG", na, 3)]
    cats = ["password", "network", "hardware", "software", "access", "email"]
    rows = []
    for i in range(1, n + 1):
        op = g.day(0, DAYS - 30)
        pr = g.pick(["low", "medium", "high", "critical"], [40, 35, 18, 7])
        res = max(0, int(g.r.expovariate(1 / {"low": 4, "medium": 3, "high": 2, "critical": 1}[pr])))
        closed = op + dt.timedelta(days=res)
        closed_s = g.d_date(closed, 0.015) if g.r.random() > 0.05 else ""  # open ticket
        sat = g.r.choice(["1", "2", "3", "4", "4", "5", "5", "5", "9"]) if g.r.random() > 0.15 else ""
        rows.append([f"TK{i:07d}", agents[g.skew(na)][0], g.d_text(g.pick(cats)), pr, g.d_date(op), closed_s, sat])
    return {"agents": (["agent_id", "team", "level"], agents),
            "tickets": (["ticket_id", "agent_id", "category", "priority", "opened_date", "closed_date",
                         "satisfaction"], g.d_dupes(rows))}


def moderation(g, n):
    nm = max(30, n // 500)
    mods = [[m, g.pick(["APAC", "EMEA", "AMER"]), g.pick(["day", "night"])] for m in ids("MD", nm, 3)]
    reasons = ["spam", "harassment", "hate_speech", "violence", "nudity", "misinformation"]
    speed = {m[0]: g.r.choice([0.8, 1.0, 1.0, 1.0, 1.5]) for m in mods}  # some moderators are slow
    rows = []
    for i in range(1, n + 1):
        reason = g.pick(reasons, [40, 20, 10, 8, 12, 10])
        act = g.pick(["none", "warn", "remove", "ban"], [45, 25, 25, 5])
        mid = mods[g.skew(nm)][0]
        rev = max(3, int(g.r.gauss(45, 20) * speed[mid]))
        if g.r.random() < 0.01:
            rev = -rev
        rows.append([f"R{i:08d}", mid, g.d_date(g.day()), g.pick(["post", "comment", "image", "video"]),
                     g.d_text(reason), act, g.d_null(str(rev))])
    return {"moderators": (["moderator_id", "region", "shift"], mods),
            "reports": (["report_id", "moderator_id", "report_date", "content_type", "reason", "action",
                         "review_seconds"], g.d_dupes(rows))}


def restaurant(g, n):
    nr = max(20, n // 1000)
    cuisines = ["malay", "chinese", "indian", "western", "japanese", "thai"]
    cities = ["Kuala Lumpur", "Penang", "Johor Bahru", "Ipoh", "Kuching"]
    rest = [[r, g.pick(cities), g.pick(cuisines)] for r in ids("RS", nr, 3)]
    items = {"malay": ["nasi lemak", "satay", "laksa"], "chinese": ["dim sum", "wonton mee", "fried rice"],
             "indian": ["roti canai", "biryani", "thosai"], "western": ["burger", "pasta", "steak"],
             "japanese": ["ramen", "sushi set", "tempura"], "thai": ["tom yum", "pad thai", "green curry"]}
    price = {}
    rows = []
    for i in range(1, n + 1):
        rr = rest[g.skew(nr)]
        item = g.pick(items[rr[2]])
        price.setdefault(item, round(g.r.uniform(6, 45), 2))
        hour = g.pick(list(range(8, 23)), [3, 3, 5, 10, 14, 8, 4, 3, 3, 6, 10, 9, 5, 3, 2])
        if g.r.random() < 0.01:
            hour = 25  # impossible hour
        rows.append([f"O{i:08d}", rr[0], g.d_date(g.day()), hour, item, g.d_null(str(g.r.randint(1, 6)), 0.015),
                     g.d_null(f"{price[item]:.2f}", 0.015), g.pick(["0", "0", "0", "5", "10", "20", ""], None),
                     g.pick(["cash", "card", "ewallet"], [30, 40, 30])])
    return {"restaurants": (["restaurant_id", "city", "cuisine"], rest),
            "orders": (["order_id", "restaurant_id", "order_date", "order_hour", "item", "qty", "unit_price",
                        "discount_pct", "payment"], g.d_dupes(rows))}


def inventory(g, n):
    ns = max(100, n // 100)
    cats = ["tools", "electronics", "office", "cleaning", "safety", "packaging"]
    prods = [[s, f"Item {s[3:]}", g.pick(cats), f"{g.r.uniform(1, 90):.2f}", str(g.r.choice([20, 50, 100, 200]))]
             for s in ids("SKU", ns, 5)]
    rows = []
    for i in range(1, n + 1):
        sku = prods[g.skew(ns)][0] if g.r.random() > 0.005 else "SKU99999"
        mt = g.pick(["in", "out", "adjust"], [52, 43, 5])
        q = g.r.randint(1, 80)
        q = q if mt == "in" else (-q if mt == "out" else g.r.choice([-3, -1, 1, 3]))
        rows.append([f"MV{i:08d}", sku, g.pick(["WH-N", "WH-S", "WH-E"]), g.d_date(g.day()), mt, g.d_null(str(q))])
    return {"products": (["sku", "product_name", "category", "unit_cost", "reorder_level"], prods),
            "stock_moves": (["move_id", "sku", "warehouse", "move_date", "move_type", "qty_change"],
                            g.d_dupes(rows))}


def political(g, n):
    nreg = max(30, n // 800)
    regs = [[f"RG{i:03d}", f"Region {i:03d}", str(g.r.randint(20000, 900000)),
             g.pick(["urban", "rural", "mixed"], [30, 40, 30])] for i in range(1, nreg + 1)]
    parties = ["Unity", "Progress", "Heritage", "Green", "Reform"]
    rows = []
    for i in range(1, n + 1):
        rg = regs[g.r.randrange(nreg)]
        p = g.pick(parties)
        bias = {"urban": {"Progress": 8, "Green": 4}, "rural": {"Heritage": 8, "Unity": 4}, "mixed": {}}[rg[3]]
        s = max(0, g.r.gauss(20 + bias.get(p, 0), 6))
        if g.r.random() < 0.01:
            s = 140.0  # impossible percentage
        rows.append([f"P{i:08d}", rg[0], g.d_date(g.day()), p, g.d_null(f"{s:.1f}"),
                     g.d_null(str(g.r.randint(200, 3000)), 0.015), g.pick(["PollCo", "VoxData", "OpinionLab"])])
    return {"regions": (["region_id", "region_name", "population", "area_type"], regs),
            "polls": (["poll_id", "region_id", "poll_date", "party", "support_pct", "sample_size", "pollster"],
                      g.d_dupes(rows))}


def healthcare(g, n):
    npat = max(100, n // 5)
    pats = [[p, str(g.r.randint(1935, 2023)), g.pick(["F", "M"]), g.pick(["north", "south", "east", "west"])]
            for p in ids("PT", npat, 6)]
    dx = [("J06", "respiratory"), ("I10", "hypertension"), ("E11", "diabetes"), ("M54", "back pain"),
          ("K29", "gastritis"), ("F41", "anxiety"), ("S93", "sprain"), ("L20", "dermatitis")]
    rows = []
    for i in range(1, n + 1):
        d = g.pick(dx, [20, 16, 14, 14, 10, 10, 9, 7])
        dept = g.pick(["general", "cardiology", "orthopedics", "emergency", "paediatrics"], [40, 15, 15, 20, 10])
        cost = round(g.r.lognormvariate(4.5, 0.7), 2)
        if g.r.random() < 0.01:
            cost = -cost
        rows.append([f"V{i:08d}", pats[g.skew(npat)][0], g.d_date(g.day()), dept, d[0],
                     g.d_null(str(max(5, int(g.r.gauss(25, 12))))), g.d_null(f"{cost:.2f}")])
    return {"patients": (["patient_id", "birth_year", "sex", "region"], pats),
            "visits": (["visit_id", "patient_id", "visit_date", "department", "diagnosis", "duration_min", "cost"],
                       g.d_dupes(rows))}


def energy(g, n):
    nm = max(50, n // 200)
    meters = [[m, g.pick(["D1", "D2", "D3", "D4", "D5"]), g.pick(["residential", "commercial", "industrial"], [70, 22, 8])]
              for m in ids("MT", nm, 5)]
    rows = []
    for i in range(1, n + 1):
        m = meters[g.r.randrange(nm)]
        hour = g.r.randrange(24)
        base = {"residential": 0.6, "commercial": 3.0, "industrial": 12.0}[m[2]]
        peak = 1.8 if 18 <= hour <= 22 else 1.0
        kwh = round(max(0, g.r.gauss(base * peak, base * 0.25)), 3)
        if g.r.random() < 0.01:
            kwh *= 8  # spike (a real anomaly the job must flag)
        if g.r.random() < 0.005:
            kwh = -kwh
        rows.append([f"RD{i:09d}", m[0], g.d_date(g.day()), hour, g.d_null(f"{kwh:.3f}"),
                     g.d_null(f"{g.r.gauss(230, 5):.1f}", 0.01)])
    return {"meters": (["meter_id", "district", "tariff"], meters),
            "readings": (["reading_id", "meter_id", "read_date", "read_hour", "kwh", "voltage"], g.d_dupes(rows))}


def education(g, n):
    courses = [[f"CS{i:03d}", g.pick(["computing", "math", "science", "business", "arts"]), str(g.r.choice([2, 3, 4]))]
               for i in range(100, 160)]
    nst = max(100, n // 6)
    rows = []
    for i in range(1, n + 1):
        c = courses[g.r.randrange(len(courses))]
        sc = min(100, max(0, g.r.gauss(62, 18)))
        if g.r.random() < 0.01:
            sc = 180.0
        rows.append([f"G{i:08d}", f"ST{g.r.randint(1, nst):06d}", c[0], g.pick(["2023S1", "2023S2", "2024S1", "2024S2"]),
                     g.d_null(f"{sc:.1f}"), g.d_date(g.day()), g.d_null(f"{g.r.uniform(40, 100):.0f}", 0.03)])
    return {"courses": (["course_id", "department", "credits"], courses),
            "grades": (["grade_id", "student_id", "course_id", "term", "score", "graded_date", "attendance_pct"],
                       g.d_dupes(rows))}


DOMAINS = {"finance": finance, "logistics": logistics, "helpdesk": helpdesk, "moderation": moderation,
           "restaurant": restaurant, "inventory": inventory, "political": political,
           "healthcare": healthcare, "energy": energy, "education": education}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows", type=int, default=None, help=f"rows in each big table (default {DEFAULT_ROWS} x scale)")
    ap.add_argument("--scale", type=float, default=1.0, help="multiply the default row count (default 1)")
    ap.add_argument("--seed", type=int, default=42, help="random seed (default 42)")
    ap.add_argument("--domain", default="all", help="one domain name, or all (default)")
    ap.add_argument("--out", default=here, help="output folder (default: this folder)")
    a = ap.parse_args()
    n = a.rows if a.rows else int(DEFAULT_ROWS * a.scale)
    names = list(DOMAINS) if a.domain == "all" else [a.domain]
    for name in names:
        if name not in DOMAINS:
            ap.error(f"unknown domain {name}. Choose from: {', '.join(DOMAINS)}")
        g = Gen(f"{a.seed}-{name}")  # one stream per domain: adding a domain does not change the others
        tables = DOMAINS[name](g, n)
        d = os.path.join(a.out, name)
        os.makedirs(d, exist_ok=True)
        for tname, (header, rows) in tables.items():
            path = os.path.join(d, tname + ".csv")
            with open(path, "w", newline="") as f:
                w = csv.writer(f, lineterminator="\n")
                w.writerow(header)
                w.writerows(rows)
            print(f"{path}: {len(rows)} rows, {os.path.getsize(path) / 1024:.0f} KiB")


if __name__ == "__main__":
    main()
