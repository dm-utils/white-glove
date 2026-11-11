"""Generates the neighbourhood map (data/maps/wijk.json): tile kinds, bin stations, team spawns, crook spawns.

Tile kinds: 0 building (wall), 1 street, 2 pavement, 3 grass (park), 4 square (school yard).
Mirror-symmetric left/right, so neither team has the better half. The output is committed; never generated at run time.
Usage: python -I tools/gen_wijk.py
"""
import json
import os

W, H = 40, 26
ROOT = os.path.join(os.path.dirname(__file__), "..")


def tiles() -> list:
    t = [[2] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if x in (0, W - 1) or y in (0, H - 1):
                t[y][x] = 0
    # streets: two long ones and three cross streets
    for y in range(H):
        for x in range(W):
            if y in (7, 8, 17, 18) or x in (6, 7, 19, 20, 32, 33):
                t[y][x] = 1
    # blocks of houses (left half; mirrored below)
    for x0, y0, x1, y1 in [(2, 2, 4, 5), (9, 2, 16, 5), (2, 10, 4, 15), (9, 10, 12, 15), (2, 20, 4, 23), (9, 20, 16, 23)]:
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                t[y][x] = 0
    # park in the middle, school yard top and bottom middle
    for y in range(10, 16):
        for x in range(14, 26):
            if t[y][x] == 2:
                t[y][x] = 3
    # mirror the left half onto the right
    for y in range(H):
        for x in range(W // 2, W):
            t[y][x] = t[y][W - 1 - x]
    for y in list(range(2, 6)) + list(range(20, 24)):
        for x in range(18, 22):
            t[y][x] = 4
    return t


def main() -> None:
    t = tiles()
    stations = [[10, 9], [27, 9], [10, 16], [27, 16]]  # mirror images: bins 10-12 on the left, 27-29 on the right
    data = {
        "name": "wijk", "width": W, "height": H,
        "_kinds": "0 building (wall), 1 street, 2 pavement, 3 grass, 4 square",
        "tiles": [v for row in t for v in row],
        # each station: bins for paper, plastic and rest next to each other (x, x+1, x+2)
        "stations": stations,
        "team_spawns": [[[5, 12], [5, 9], [5, 16]], [[34, 12], [34, 9], [34, 16]]],
        "crook_spawns": [[19, 2], [20, 23], [13, 12], [26, 12], [19, 12], [20, 12]],
    }
    path = os.path.join(ROOT, "data", "maps", "wijk.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, separators=(",", ":"))
        fh.write("\n")
    print("wrote", os.path.normpath(path))
    for row in t:
        print("".join("#=.,:"[v] for v in row))


if __name__ == "__main__":
    main()
