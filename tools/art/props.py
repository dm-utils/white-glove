"""Builds the White Glove things as SVGs (stdlib only): litter, bins and crooks, one file per kind in assets/props/,
the same style as the heroes (thick ink outline, flat colours, one highlight).

Litter and bins are 200 x 200 with the foot point at (100, 150); crooks are 200 x 240 with the feet at (100, 200),
like the heroes. Bin colours: paper navy, plastic yellow, rest grey (never the team colours blue/orange).
Usage: python -I tools/art/props.py
"""
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OUT = os.path.join(ROOT, "assets", "props")
INK = "#2B3A4A"
SKIN = "#E9B98E"
S = f'stroke="{INK}" stroke-width="7" stroke-linejoin="round" stroke-linecap="round"'
BIN = {"paper": "#2F5DA8", "plastic": "#F2C230", "rest": "#7A828C"}


def shadow(rx: int = 46) -> str:
    return f'<ellipse cx="100" cy="150" rx="{rx}" ry="12" fill="#000" opacity="0.18"/>'


def paper_icon(cx: int, cy: int, k: float = 1.0) -> list:
    w, h = 22 * k, 28 * k
    return [f'<rect x="{cx - w / 2}" y="{cy - h / 2}" width="{w}" height="{h}" rx="3" fill="#FFFFFF" stroke="{INK}" stroke-width="3"/>',
            f'<path d="M{cx - w / 3} {cy - h / 5} H{cx + w / 3} M{cx - w / 3} {cy + h / 8} H{cx + w / 3}" stroke="{INK}" stroke-width="2.5"/>']


def bottle_icon(cx: int, cy: int, k: float = 1.0) -> list:
    return [f'<path d="M{cx - 4 * k} {cy - 16 * k} h{8 * k} v{6 * k} q{6 * k} {4 * k} {6 * k} {10 * k} v{16 * k} h{-20 * k} v{-16 * k} q0 {-6 * k} {6 * k} {-10 * k} Z" '
            f'fill="#FFFFFF" stroke="{INK}" stroke-width="3" stroke-linejoin="round"/>']


def core_icon(cx: int, cy: int, k: float = 1.0) -> list:
    return [f'<path d="M{cx - 9 * k} {cy - 12 * k} q{-6 * k} {12 * k} 0 {24 * k} h{18 * k} q{6 * k} {-12 * k} 0 {-24 * k} Z" fill="#FFFFFF" stroke="{INK}" stroke-width="3"/>',
            f'<path d="M{cx} {cy - 12 * k} v{-6 * k}" stroke="{INK}" stroke-width="3"/>']


ICONS = {"paper": paper_icon, "plastic": bottle_icon, "rest": core_icon}


def bin_svg(kind: str) -> list:
    c = BIN[kind]
    return [shadow(44),
            f'<path d="M58 70 H142 L134 148 H66 Z" fill="{c}" {S}/>',
            f'<rect x="50" y="56" width="100" height="18" rx="8" fill="{c}" {S}/>',
            '<rect x="68" y="80" width="10" height="56" rx="5" fill="#FFFFFF" opacity="0.25"/>',
            f'<circle cx="100" cy="108" r="24" fill="{c}" stroke="#FFFFFF" stroke-width="5"/>'] + ICONS[kind](100, 108, 1.0)


PROPS = {
    # crumpled paper: a white ball with fold lines
    "litter_paper": [shadow(26),
                     f'<path d="M78 140 L72 116 L86 98 L110 96 L128 110 L126 136 L104 146 Z" fill="#FFFFFF" {S}/>',
                     f'<path d="M86 100 L96 122 L124 112 M96 122 L92 142 M96 122 L118 134" fill="none" stroke="{INK}" stroke-width="3.5"/>'],
    # a plastic bottle lying down
    "litter_plastic": [shadow(40),
                       f'<path d="M62 116 Q62 104 74 104 H118 Q126 104 132 110 H144 V130 H132 Q126 136 118 136 H74 Q62 136 62 124 Z" fill="#9FE3F5" {S}/>',
                       f'<rect x="140" y="112" width="14" height="16" rx="3" fill="#3F8CFF" {S}/>',
                       '<rect x="74" y="111" width="40" height="7" rx="3" fill="#FFFFFF" opacity="0.7"/>',
                       f'<rect x="84" y="104" width="22" height="32" fill="#E8503A" stroke="{INK}" stroke-width="3.5"/>'],
    # an apple core
    "litter_rest": [shadow(26),
                    f'<path d="M82 92 Q70 92 74 106 Q88 118 74 132 Q72 146 88 146 H112 Q128 146 126 132 Q112 118 126 106 Q130 92 118 92 Z" fill="#FFF1C9" {S}/>',
                    f'<path d="M80 92 Q100 84 120 92 M80 146 Q100 152 120 146" fill="none" stroke="#D94A3A" stroke-width="9" stroke-linecap="round"/>',
                    f'<path d="M100 88 Q102 76 108 70" fill="none" stroke="{INK}" stroke-width="6" stroke-linecap="round"/>',
                    f'<ellipse cx="96" cy="118" rx="4" ry="6" fill="{INK}"/><ellipse cx="106" cy="122" rx="4" ry="6" fill="{INK}"/>'],
    "bin_paper": bin_svg("paper"),
    "bin_plastic": bin_svg("plastic"),
    "bin_rest": bin_svg("rest"),
}


def crook(helping: bool) -> list:
    """A litterbug in a hoodie. Helping: hood down, a big smile, a litter picker and a white glove."""
    hood = "#8E6FB8"
    parts = [
        '<ellipse cx="100" cy="200" rx="44" ry="11" fill="#000" opacity="0.18"/>',
        f'<rect x="78" y="160" width="18" height="38" rx="8" fill="#4A5160"/>',
        f'<rect x="104" y="160" width="18" height="38" rx="8" fill="#4A5160"/>',
        f'<rect x="66" y="104" width="68" height="66" rx="20" fill="{hood}" {S}/>',
        f'<rect x="80" y="140" width="40" height="16" rx="6" fill="{hood}" stroke="{INK}" stroke-width="4"/>',  # pocket
        f'<rect x="50" y="112" width="20" height="44" rx="10" fill="{hood}" {S}/>',
        f'<rect x="130" y="112" width="20" height="44" rx="10" fill="{hood}" {S}/>',
    ]
    if helping:
        parts += [
            f'<circle cx="100" cy="76" r="32" fill="{SKIN}" {S}/>',
            f'<path d="M68 96 Q100 116 132 96" fill="none" stroke="{hood}" stroke-width="12" stroke-linecap="round"/>',  # hood down
            f'<circle cx="90" cy="74" r="4.5" fill="{INK}"/><circle cx="112" cy="74" r="4.5" fill="{INK}"/>',
            f'<path d="M86 86 Q101 102 116 86" fill="#FFFFFF" stroke="{INK}" stroke-width="4" stroke-linejoin="round"/>',
            f'<path d="M150 150 L176 40" fill="none" stroke="{INK}" stroke-width="10" stroke-linecap="round"/>',  # picker
            '<path d="M150 150 L176 40" fill="none" stroke="#C9CED6" stroke-width="5" stroke-linecap="round"/>',
            f'<path d="M144 150 L140 172 M156 152 L160 172" fill="none" stroke="{INK}" stroke-width="6" stroke-linecap="round"/>',
            f'<circle cx="146" cy="150" r="13" fill="#FFFFFF" {S}/>',  # the white glove
        ]
    else:
        parts += [
            f'<path d="M64 84 Q64 38 100 38 Q136 38 136 84 Q136 110 100 110 Q64 110 64 84 Z" fill="{hood}" {S}/>',  # hood up
            f'<ellipse cx="100" cy="82" rx="24" ry="22" fill="{SKIN}" stroke="{INK}" stroke-width="5"/>',
            f'<path d="M86 76 L96 80 M114 76 L104 80" stroke="{INK}" stroke-width="4" stroke-linecap="round"/>',  # sneaky brows
            f'<circle cx="92" cy="84" r="4" fill="{INK}"/><circle cx="108" cy="84" r="4" fill="{INK}"/>',
            f'<path d="M92 96 Q100 92 108 96" fill="none" stroke="{INK}" stroke-width="3.5" stroke-linecap="round"/>',
        ]
    return parts


def write(name: str, parts: list, h: int = 200) -> None:
    svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="200" height="{h}" viewBox="0 0 200 {h}">' + "".join(parts) + "</svg>\n"
    with open(os.path.join(OUT, f"{name}.svg"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(svg)


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    for name, parts in PROPS.items():
        write(name, parts)
    write("crook", crook(False), 240)
    write("crook_helper", crook(True), 240)
    print("wrote", len(PROPS) + 2, "props to", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
