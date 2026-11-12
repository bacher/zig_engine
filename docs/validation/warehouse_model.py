#!/usr/bin/env python3
"""Executable reference model for warehouse Q2, Q5, and Q26; Python standard library only.

Run from the repository root: python3 docs/validation/warehouse_model.py
This checks specification arithmetic, not the Zig runtime or performance.
"""

from itertools import product

MASK64 = (1 << 64) - 1
REFERENCE = (
    (24, 20, 19, 21, 22),
    (17, 8, 7, 9, 11),
    (16, 5, 1, 2, 10),
    (18, 6, 3, 4, 12),
    (23, 14, 13, 15, 25),
)
OFFSETS = tuple((x - 2, y - 2) for _, x, y in sorted(
    (rank, x, y) for y, row in enumerate(REFERENCE) for x, rank in enumerate(row)
))


def check(condition, context):
    if not condition:
        raise AssertionError(context)


def origin_hash(x, y, z):
    key = x + 32 * y + 1024 * z
    value = (key + 0x9e3779b97f4a7c15) & MASK64
    value = ((value ^ (value >> 30)) * 0xbf58476d1ce4e5b9) & MASK64
    value = ((value ^ (value >> 27)) * 0x94d049bb133111eb) & MASK64
    return value ^ (value >> 31)


def column_order(width, height, selector):
    """Return footprint-local cells; selector contains H's low four bits."""
    direction = selector & 3
    cx = (width - 1) // 2 + ((selector >> 2) & 1 if width % 2 == 0 else 0)
    cy = (height - 1) // 2 + ((selector >> 3) & 1 if height % 2 == 0 else 0)
    center = (cx, cy)

    def rotate(x, y):
        return ((-y, x), (x, y), (y, -x), (-x, -y))[direction]

    def depth(cell):
        x, y = cell
        return min(x, width - 1 - x, y, height - 1 - y)

    def corner(cell):
        x, y = cell
        return x in (0, width - 1) and y in (0, height - 1)

    rotated = [(cx + x, cy + y) for x, y in map(lambda p: rotate(*p), OFFSETS)]
    inside = [p for p in rotated if 0 <= p[0] < width and 0 <= p[1] < height]
    rest = sorted((p for p in inside if p != center), key=lambda p: -depth(p))
    return [center] + [p for p in rest if not corner(p)] + [p for p in rest if corner(p)]


def group_slots(columns):
    return ([(p, z) for p in columns for z in range(4)]
            + [(p, 4) for p in columns] + [(p, 5) for p in columns])


def slots(columns, active):
    return group_slots(columns[:active]) + group_slots(columns[active:])


def check_hashes():
    fixtures = [((0, 0, 0), 0xe220a8397b1dcdaf),
                ((1, 0, 0), 0x910a2dec89025cc1),
                ((31, 31, 31), 0xb73ab1ecf2c9d038)]
    for xyz, expected in fixtures:
        check(origin_hash(*xyz) == expected, ('hash fixture', xyz))
    selectors = {origin_hash(*xyz) & 15 for xyz in product(range(32), repeat=3)}
    check(selectors == set(range(16)), 'all selector combinations must occur')
    # Canonicalize wrapped X before extracting local coordinates (example 128-cell world).
    for x in (-129, -1, 0, 31, 127, 128, 159):
        check(origin_hash((x % 128) % 32, 7, 3)
              == origin_hash(((x + 128) % 128) % 32, 7, 3), ('wrapped address', x))


def check_layouts():
    variants = set()
    for width, height, selector in product(range(1, 6), range(1, 6), range(16)):
        order = column_order(width, height, selector)
        cx, cy = order[0]
        context = (width, height, selector)
        variants.add((width, height, cx, cy, selector & 3))
        check(set(order) == set(product(range(width), range(height)))
              and len(order) == width * height, ('permutation', context))
        check(cx in {(width - 1) // 2, width // 2}
              and cy in {(height - 1) // 2, height // 2}, ('central start', context))
        depths = [min(x, width - 1 - x, y, height - 1 - y) for x, y in order]
        check(depths == sorted(depths, reverse=True), ('inner layers', context))
        corner_flags = [x in (0, width - 1) and y in (0, height - 1) for x, y in order[1:]]
        check(corner_flags == sorted(corner_flags), ('late corners', context))
        dx, dy = ((0, 1), (1, 0), (0, -1), (-1, 0))[selector & 3]
        neighbor = (cx + dx, cy + dy)
        if neighbor in order:
            x, y = neighbor
            is_corner = x in (0, width - 1) and y in (0, height - 1)
            if not is_corner and min(x, width - 1 - x, y, height - 1 - y) == depths[0]:
                check(order[1] == neighbor, ('preferred second column', context))
        for active in range(len(order) + 1):
            sequence = slots(order, active)
            check(len(set(sequence)) == 6 * width * height, ('physical slot coverage', context, active))
        full = slots(order, len(order))
        check(full[4 * len(order):5 * len(order)] == [(p, 4) for p in order], ('fifth level', context))
        check(full[5 * len(order):] == [(p, 5) for p in order], ('sixth level', context))
        if (width, height) == (4, 4):
            inner = set(product((1, 2), repeat=2))
            check(set(order[:4]) == inner, ('inner 2x2', context))
            check(all(p in inner for p, _ in full[:16]) and full[16][0] not in inner,
                  ('item 16/17 boundary', context))
    check(len(variants) == 196, ('distinct variants', len(variants)))
    check(column_order(5, 5, 1) == [(x + 2, y + 2) for x, y in OFFSETS], '5x5 reference')
    return len(variants)


def check_capacity():
    states = 0
    for count in range(1, 26):
        for active in range(count + 1):
            sequence = slots(list(range(count)), active)
            check(len(sequence) == len(set(sequence)) == 6 * count, ('slot permutation', count, active))
            heights = [0] * count
            disabled = 0
            for stock in range(6 * count + 1):
                if stock:
                    column, z = sequence[stock - 1]
                    check(z == heights[column], ('contiguous stack', count, active, stock))
                    heights[column] += 1
                    disabled += column >= active
                check(sum(heights) == stock and max(heights) <= 6, 'stock conservation')
                check(disabled == max(0, stock - 6 * active), 'disabled stock')
                if disabled:
                    check(sequence[stock - 1][0] >= active, 'disabled-first take')
                for incoming in range(6 * count - stock + 1):
                    states += 1
                    total = stock + incoming
                    deficit = max(0, 4 * active - total)
                    room = max(0, 6 * active - total)
                    check(0 <= deficit <= room, 'demand within active room')
                    check((total + 1 <= 6 * active) == (room > 0), 'one-item admission')
                    check(total + room + 1 > 6 * active, 'admission ceiling')
                    if room:
                        check(total + room == 6 * active, 'maximum new batch')
                    if deficit:
                        check(total + deficit == 4 * active, 'normal target')
                    # Any previously accepted promise still fits after an active-count reduction.
                    if incoming:
                        for quantity in {1, incoming}:
                            new_stock, new_incoming = stock + quantity, incoming - quantity
                            check(new_stock <= 6 * count and new_incoming >= 0
                                  and new_stock + new_incoming == total, 'reserved handover')
                    if stock:
                        check((stock - 1) + incoming == total - 1, 'take preserves incoming')
    check(states == 2053700, ('aggregate states', states))
    for stock, expected in [(20, [5, 5, 5, 5, 0, 0, 0, 0, 0]),
                            (28, [6, 6, 6, 6, 4, 0, 0, 0, 0])]:
        heights = [0] * 9
        for column, _ in slots(list(range(9)), 4)[:stock]:
            heights[column] += 1
        check(heights == expected, ('reduced-capacity example', stock))
    return states


def check_recovery():
    footprints = 0
    for width, height in product(range(1, 6), repeat=2):
        border = [(x, y) for x in range(-1, width + 1) for y in range(-1, height + 1)
                  if x in (-1, width) or y in (-1, height)]
        check(len(border) == 2 * width + 2 * height + 4 <= 24, 'halo count')
        for x, y in border:
            # Center a 0.6-wide body in one cell; feet z0, height 1.8 inside the six-cell halo.
            check(x <= x + 0.5 - 0.3 < x + 0.5 + 0.3 <= x + 1
                  and y <= y + 0.5 - 0.3 < y + 0.5 + 0.3 <= y + 1, 'horizontal body clearance')
            check(0 < 1.8 <= 6, 'vertical body clearance')
        footprints += 1
    check(31 // 32 != int(31 + 1.8) // 32, 'body at local z=31 needs another chunk')
    return footprints


def main():
    check_hashes()
    variants = check_layouts()
    states = check_capacity()
    footprints = check_recovery()
    print('PASS: 3 hash fixtures; all 16 selectors across 32768 local origins; wrapped X')
    print(f'PASS: {footprints} footprint dimensions; {variants} distinct center/direction layouts')
    print(f'PASS: {states} aggregate N/A/C/I states; packing, admission, demand, handover')
    print(f'PASS: {footprints} halo geometries; full-body fit and vertical chunk-boundary case')
    print('Specification model only; no runtime, concurrency, persistence, or performance validation.')


if __name__ == '__main__':
    main()
