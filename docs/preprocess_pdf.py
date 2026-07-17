#!/usr/bin/env python3
"""
preprocess_pdf.py — transforme les .md sources pour générer un PDF
autonome avec des liens internes cliquables.

Usage :
    preprocess_pdf.py <src_dir> <dst_dir>

Où :
    <src_dir> : dossier source (ex: docs/fr/)
    <dst_dir> : dossier de sortie (ex: docs/build_fr/)

Les transformations appliquées :
  1. Injection d'un ID explicite au H1 de chaque chapitre ({#ch-xxx})
     pour que pandoc génère des ancres prévisibles.
  2. Strip des toggles "English | Français" / "[English](...) | [Français](...)".
  3. Conversion des liens [xxx](xxx.md) → [xxx](#ch-xxx).
  4. Conversion des liens [xxx](modules/xxx.md) → [xxx](#ch-xxx).
  5. Conversion des liens [xxx](../security.md) → [xxx](#ch-security)
     et autres références relatives entre modules.
  6. Reformulation des références à manual_order_*.txt (lien mort dans PDF).
     dans les exemples de sortie CLI.

Les fichiers sources NE SONT JAMAIS modifiés. Tout est écrit dans
<dst_dir>, qui est destiné à être éphémère (nettoyé par build_doc.sh).
"""

import os
import re
import shutil
import sys
from pathlib import Path


# ----------------------------------------------------------------------
# Mapping fichier → ID d'ancre pandoc
# ----------------------------------------------------------------------
#
# La clé est le NOM DE BASE du fichier (sans extension, sans chemin).
# La valeur est l'ID utilisé comme ancre.
#
# On garde la même map pour EN et FR : les liens utilisent le même ID,
# seul le contenu textuel des titres diffère.
FILE_TO_ANCHOR = {
    "README":          "ch-readme",
    "getting-started": "ch-getting-started",
    "security":        "ch-security",
    "cookbook":        "ch-cookbook",
    "argparse":        "ch-argparse",
    "archive":         "ch-archive",
    "base64":          "ch-base64",
    "compression":     "ch-compression",
    "exec":            "ch-exec",
    "fs":              "ch-fs",
    "http":            "ch-http",
    "inotify":         "ch-inotify",
    "json":            "ch-json",
    "logging":         "ch-logging",
    "pipeline":        "ch-pipeline",
    "signal":          "ch-signal",
    "socket":          "ch-socket",
    "sqlite":          "ch-sqlite",
    "strings":         "ch-strings",
    "sys":             "ch-sys",
    "tables":          "ch-tables",
    "time":            "ch-time",
    "tls":             "ch-tls",
    "toml":            "ch-toml",
    "user":            "ch-user",
    "workers":         "ch-workers",
    "write-file-atomic": "ch-write-file-atomic",
}


def filename_to_anchor(filename):
    """Convertit un nom de fichier (avec ou sans .md) en ID d'ancre.

    Retourne None si le fichier n'est pas dans la map.
    """
    # Strip path components and .md extension
    base = os.path.basename(filename)
    if base.endswith(".md"):
        base = base[:-3]
    return FILE_TO_ANCHOR.get(base)


# ----------------------------------------------------------------------
# Transformations
# ----------------------------------------------------------------------

def inject_h1_id(content, anchor_id):
    """Injecte {#anchor_id} à la fin du premier H1 du fichier.

    `# Titre` → `# Titre {#anchor_id}`

    Si le H1 a déjà un {#id}, on ne touche pas (sécurité).
    """
    lines = content.split("\n")
    for i, line in enumerate(lines):
        # Match H1 simple : une seule '#' au début, suivi d'au moins
        # un espace puis du contenu. Évite de matcher ## ou ###.
        match = re.match(r'^# (?!#)(.+?)\s*$', line)
        if match:
            title = match.group(1)
            # Si l'attribut {#xxx} est déjà là, on ne touche pas.
            if re.search(r'\{#[^}]+\}\s*$', title):
                return content
            lines[i] = f"# {title} {{#{anchor_id}}}"
            return "\n".join(lines)
    return content




def convert_html_anchors_to_heading_ids(content):
    """Convert source-friendly HTML anchors into Pandoc heading IDs.

    The Markdown sources use ``<a id="..."></a>`` so GitHub and other
    renderers expose stable anchors without displaying Pandoc attributes.
    Raw HTML anchors do not create LaTeX labels, however, so the transient PDF
    copy rewrites:

        <a id="mkdir"></a>
        ### `babet.mkdir(path)`

    into:

        ### `babet.mkdir(path)` {#mkdir}
    """
    pattern = re.compile(
        r'^<a id="([A-Za-z0-9_.:-]+)"></a>\n(?:[ \t]*\n)*(#{1,6}) (.+)$',
        re.MULTILINE,
    )

    def replace(match):
        anchor, hashes, title = match.groups()
        if re.search(r'\{#[^}]+\}\s*$', title):
            return f"{hashes} {title}"
        return f"{hashes} {title} {{#{anchor}}}"

    return pattern.sub(replace, content)


def strip_language_toggle(content):
    """Supprime la ligne de toggle linguistique en haut des fichiers.

    Patterns supportés :
      [English](xxx) | **Français**
      **English** | [Français](xxx)
      > [English](xxx) | **Français**
      > **English** | [Français](xxx)
    """
    lines = content.split("\n")
    out = []
    for line in lines:
        stripped = line.strip().lstrip(">").strip()
        # Le toggle contient toujours un lien Markdown vers ../en/ ou
        # ../fr/ ou ../../en/ ou ../../fr/, avec le mot English ou
        # Français en une seule paire.
        if re.match(
            r'^(\*\*English\*\*|\[English\]\([^)]+\))\s*\|\s*'
            r'(\*\*Fran[çc]ais\*\*|\[Fran[çc]ais\]\([^)]+\))\s*$',
            stripped
        ):
            continue
        out.append(line)
    return "\n".join(out)


def transform_internal_links(content):
    """Transforme les liens [...](xxx.md) en [...](#ch-xxx).

    Couvre tous les patterns relatifs trouvés dans la doc :
      - `[fs](modules/fs.md)`                  (depuis README/getting-started)
      - `[security](security.md)`               (depuis README/getting-started)
      - `[security](../security.md)`            (depuis un module vers security)
      - `[signal](signal.md)`                   (entre modules, même dossier)
      - `[signal](modules/signal.md)`           (depuis README vers module)
      - `[cwd](modules/fs.md#fs-cwd)`            (vers une ancre d'un autre chapitre)
      - `[modules/](modules/)`                  (lien vers le dossier)
      - `[manual_order_fr.txt](../manual_order_fr.txt)` (lien mort en PDF)
    """
    def replace(match):
        text = match.group(1)
        target = match.group(2)

        # Cas spécial 0 : lien externe (http://, https://, mailto:, ftp:).
        # On NE TOUCHE PAS. Ce check doit être en PREMIER, avant tout
        # mapping, sinon une URL qui finit par /json ou /socket serait
        # transformée par erreur en ancre interne (l'extraction de
        # basename voit "json" et le mapping s'applique).
        if re.match(r'^[a-z]+://', target) or target.startswith('mailto:'):
            return match.group(0)

        # Cas spécial 1 : lien vers une ancre explicite d'un autre
        # fichier Markdown. Dans le PDF fusionné, tous les chapitres
        # partagent le même document : seule l'ancre finale est utile.
        if "#" in target:
            path_part, fragment = target.split("#", 1)
            if path_part.endswith(".md") and fragment:
                return f"[{text}](#{fragment})"

        # Cas spécial 2 : `modules/` (lien vers le dossier modules)
        # → pas d'équivalent dans le PDF, on garde le texte sans lien
        if target.rstrip("/") == "modules":
            return f"`{text}`" if not text.startswith("`") else text

        # Cas spécial 3 : manual_order_*.txt (manifeste, lien mort en PDF)
        # → on garde le texte sans lien
        if "manual_order_" in target and target.endswith(".txt"):
            return f"`{text}`" if not text.startswith("`") else text

        # Cas général : essayer de mapper target → ancre
        anchor = filename_to_anchor(target)
        if anchor:
            return f"[{text}](#{anchor})"

        # Lien interne non-mappé : on laisse tel quel et on logge un warning
        sys.stderr.write(
            f"  warning: unmapped link [{text}]({target}) — kept as-is\n"
        )
        return match.group(0)

    # Regex : [texte](cible) où cible ne commence pas par # (déjà une ancre)
    # et n'est pas vide. On capture text+target.
    pattern = re.compile(r'\[([^\]]+)\]\(([^)#][^)]*)\)')
    return pattern.sub(replace, content)


def fix_manual_order_reference(content):
    """Reformule les références au fichier manual_order_*.txt.

    Dans le PDF, dire « voir docs/manual_order_fr.txt » n'a aucun sens
    parce que le fichier n'existe pas dans le PDF. On garde la mention
    informative mais on enlève toute prétention de lien.

    Ici on ne fait rien de spécifique : c'est déjà géré par
    transform_internal_links() qui retire le lien et garde le texte.
    """
    return content


# ----------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------

def process_file(src_path, dst_path):
    """Lit src_path, applique toutes les transformations, écrit dst_path."""
    with open(src_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Étape 1 : strip les toggles de langue (1ère ligne typiquement)
    content = strip_language_toggle(content)

    # Étape 2 : injecter l'ID au H1 (si on a un mapping pour ce fichier)
    anchor = filename_to_anchor(src_path)
    if anchor:
        content = inject_h1_id(content, anchor)

    # Étape 3 : convertir les ancres HTML stables des sources en attributs
    # de titre Pandoc, afin qu'elles deviennent aussi des labels LaTeX.
    content = convert_html_anchors_to_heading_ids(content)

    # Étape 4 : transformer les liens internes
    content = transform_internal_links(content)

    # (L'étape « corriger les valeurs obsolètes » a été retirée : le
    # Markdown source est la seule source de vérité ; on ne masque
    # plus de valeurs périmées à la génération PDF.)

    # Étape 5 : reformuler références à manual_order_*.txt
    content = fix_manual_order_reference(content)

    # Écrire le résultat
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(content)


def process_directory(src_dir, dst_dir):
    """Traite récursivement tous les .md de src_dir vers dst_dir."""
    src = Path(src_dir)
    dst = Path(dst_dir)

    if not src.is_dir():
        sys.stderr.write(f"error: {src_dir} is not a directory\n")
        sys.exit(1)

    # Nettoyer le dossier de destination s'il existe
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    md_files = sorted(src.rglob("*.md"))
    if not md_files:
        sys.stderr.write(f"warning: no .md files found in {src_dir}\n")
        return

    print(f"preprocess_pdf: {src_dir} -> {dst_dir} ({len(md_files)} files)")

    for src_file in md_files:
        rel = src_file.relative_to(src)
        dst_file = dst / rel
        process_file(src_file, dst_file)

    print(f"preprocess_pdf: done.")


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        sys.exit(1)

    src_dir = sys.argv[1]
    dst_dir = sys.argv[2]
    process_directory(src_dir, dst_dir)


if __name__ == "__main__":
    main()
