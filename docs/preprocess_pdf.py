#!/usr/bin/env python3
"""
preprocess_pdf.py — transforme les .md sources pour générer un PDF
autonome avec des liens internes cliquables.

Usage :
    preprocess_pdf.py <src_dir> <dst_dir> [<order_file>]

Où :
    <src_dir>    : dossier source (ex: docs/fr/)
    <dst_dir>    : dossier de sortie (ex: docs/build_fr/)
    <order_file> : manifeste des chapitres ; par défaut
                   <src_dir>/../manual_order_<langue>.txt

Les transformations appliquées :
  1. Injection d'un ID explicite au H1 de chaque chapitre ({#ch-xxx})
     pour que pandoc génère des ancres prévisibles.
  2. Strip des toggles "English | Français" / "[English](...) | [Français](...)".
  3. Conversion des liens vers un chapitre du manuel en ancres internes :
     [xxx](modules/xxx.md) → [xxx](#ch-xxx), [xxx](fs.md#mkdir) → [xxx](#mkdir).
  4. Conversion des liens vers un autre fichier du dépôt (CHANGELOG,
     exemples…) en URL GitHub : le lecteur du PDF n'a pas l'arborescence.
  5. Reformulation des références à manual_order_*.txt (lien mort dans PDF).

La liste des chapitres vient UNIQUEMENT du manifeste manual_order_<langue>.txt :
ajouter un chapitre au manifeste suffit, il n'y a plus de table à tenir à jour
ici. Chaque lien est résolu par son chemin réel, depuis le fichier qui le
contient.

Tout lien qui ne peut pas être rendu correctement dans le PDF est une ERREUR
et fait échouer la génération (code de sortie 1) :
  - lien vers un fichier absent du dépôt ;
  - lien vers un .md de la documentation absent du manifeste ;
  - .md présent dans <src_dir> mais absent du manifeste (chapitre oublié).

Les fichiers sources NE SONT JAMAIS modifiés. Tout est écrit dans
<dst_dir>, qui est destiné à être éphémère (nettoyé par build_doc.sh).
"""

import os
import re
import shutil
import sys
from pathlib import Path
from urllib.parse import quote


# ----------------------------------------------------------------------
# Liens vers le dépôt
# ----------------------------------------------------------------------
#
# Un lien relatif vers un fichier hors du manuel (../../CHANGELOG.md,
# ../../../examples/…) fonctionne sur GitHub mais pas dans un PDF isolé.
# Il est réécrit vers le dépôt public. BABET_DOCS_REF permet de viser un
# tag précis (ex: BABET_DOCS_REF=v2.35.0 ./build_doc.sh) ; par défaut la
# branche principale, qui existe toujours.
REPO_URL = os.environ.get(
    "BABET_DOCS_REPO_URL", "https://github.com/Chipsterjulien/babet"
).rstrip("/")
REPO_REF = os.environ.get("BABET_DOCS_REF", "main")


class LinkContext:
    """Contexte de résolution des liens pour une langue du manuel."""

    def __init__(self, src_dir, repo_root, chapters):
        self.src_dir = src_dir        # docs/<langue>, chemin absolu normalisé
        self.repo_root = repo_root    # racine du dépôt, chemin absolu normalisé
        self.chapters = chapters      # {chemin absolu du chapitre: ancre}
        self.errors = []

    def error(self, src_path, line, message):
        try:
            shown = os.path.relpath(src_path, self.repo_root)
        except ValueError:
            shown = str(src_path)
        self.errors.append(f"{shown}:{line}: {message}")


def chapter_anchor(path):
    """Ancre d'un chapitre : ch-<nom de base en minuscules>."""
    return "ch-" + Path(path).stem.lower()


def read_order_file(order_file):
    """Lit le manifeste : une entrée par ligne, relative à la racine du dépôt."""
    entries = []
    with open(order_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                entries.append(line)
    return entries


def load_chapters(src_dir, order_file):
    """Construit {chemin absolu: ancre} depuis le manifeste.

    Retourne (repo_root, chapters, problems). Les entrées du manifeste sont
    relatives à la racine du dépôt, c'est-à-dire au parent de docs/.
    """
    repo_root = os.path.normpath(os.path.join(os.path.dirname(order_file), ".."))
    chapters = {}
    anchors = {}
    problems = []
    for entry in read_order_file(order_file):
        path = os.path.normpath(os.path.join(repo_root, entry))
        if os.path.commonpath([path, src_dir]) != src_dir:
            continue  # entrée d'une autre langue : pas concernée ici
        if not os.path.isfile(path):
            problems.append(f"{order_file}: chapitre introuvable : {entry}")
            continue
        anchor = chapter_anchor(path)
        if anchor in anchors and anchors[anchor] != path:
            problems.append(
                f"{order_file}: {entry} et "
                f"{os.path.relpath(anchors[anchor], repo_root)} "
                f"produisent la même ancre #{anchor}"
            )
            continue
        anchors[anchor] = path
        chapters[path] = anchor
    return repo_root, chapters, problems


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

    Les deux ordres sont acceptés (English | Français ou l'inverse).
    La ligne est vidée plutôt que retirée : les numéros de ligne des
    diagnostics restent ceux du fichier source.
    """
    # Un élément du toggle : la langue courante en gras, ou un lien
    # Markdown vers l'autre langue.
    item = r'(?:\*\*(?:English|Fran[çc]ais)\*\*|\[(?:English|Fran[çc]ais)\]\([^)]+\))'
    toggle = re.compile(rf'^{item}\s*\|\s*{item}\s*$')
    lines = content.split("\n")
    out = []
    for line in lines:
        stripped = line.strip().lstrip(">").strip()
        if toggle.match(stripped):
            out.append("")
            continue
        out.append(line)
    return "\n".join(out)


def fenced_code_spans(content):
    """Retourne les intervalles [début, fin) des blocs de code clôturés.

    Un bloc s'ouvre par au moins trois ` ou ~ en début de ligne (indentation
    libre, pour les blocs placés dans une liste) et se ferme par une clôture
    du même caractère, au moins aussi longue.
    """
    spans = []
    offset = 0
    fence = None  # (caractère, longueur, début)
    for line in content.split("\n"):
        match = re.match(r'^[ \t]*(`{3,}|~{3,})(.*)$', line)
        if match:
            run, rest = match.group(1), match.group(2)
            if fence is None:
                fence = (run[0], len(run), offset)
            elif run[0] == fence[0] and len(run) >= fence[1] and not rest.strip():
                spans.append((fence[2], offset + len(line)))
                fence = None
        offset += len(line) + 1
    if fence is not None:  # bloc non refermé : jusqu'à la fin du fichier
        spans.append((fence[2], len(content)))
    return spans


def in_inline_code(content, position):
    """Vrai si `position` est dans un passage `code` ouvert sur la même ligne.

    Un nombre impair de séries d'accents graves entre le début de la ligne
    et la position signifie qu'un passage de code est ouvert. Le texte d'un
    lien peut lui-même contenir du code ([`x`](y)) : seul ce qui précède le
    crochet ouvrant compte.
    """
    line_start = content.rfind("\n", 0, position) + 1
    return len(re.findall(r'`+', content[line_start:position])) % 2 == 1


def repo_url_for(ctx, resolved, fragment):
    """URL publique d'un fichier ou dossier du dépôt."""
    rel = os.path.relpath(resolved, ctx.repo_root).replace(os.sep, "/")
    kind = "tree" if os.path.isdir(resolved) else "blob"
    url = f"{REPO_URL}/{kind}/{quote(REPO_REF, safe='')}/{quote(rel)}"
    return f"{url}#{fragment}" if fragment else url


def transform_internal_links(content, src_path, ctx):
    """Réécrit les liens relatifs pour le PDF fusionné.

    Chaque cible est résolue depuis le fichier source, puis :
      - chapitre du manuel            → ancre interne (#ch-xxx ou #fragment) ;
      - `modules/` ou manual_order_*  → texte seul (pas d'équivalent PDF) ;
      - autre fichier du dépôt        → URL GitHub ;
      - tout le reste                 → erreur enregistrée dans ctx.

    Les liens externes, les images et le contenu des blocs ou passages de
    code ne sont pas touchés.
    """
    fences = fenced_code_spans(content)

    def replace(match):
        text = match.group(1)
        target = match.group(2).strip()
        start = match.start()

        # Image : ![alt](chemin) — pandoc a besoin du chemin local.
        if start > 0 and content[start - 1] == "!":
            return match.group(0)

        # Exemple de code : `handlers[name](arg)` n'est pas un lien.
        if any(begin <= start < end for begin, end in fences):
            return match.group(0)
        if in_inline_code(content, start):
            return match.group(0)

        # Lien externe (http://, https://, mailto:, ftp:) : on NE TOUCHE
        # PAS. Ce check passe avant toute résolution de chemin.
        if re.match(r'^[a-z][a-z0-9+.-]*://', target) or target.startswith('mailto:'):
            return match.group(0)

        line = content.count("\n", 0, start) + 1
        path_part, _, fragment = target.partition("#")
        resolved = os.path.normpath(
            os.path.join(os.path.dirname(src_path), path_part)
        )

        # Lien vers un chapitre du manuel. Dans le PDF fusionné, tous les
        # chapitres partagent le même document : avec une ancre explicite,
        # seule l'ancre finale est utile.
        anchor = ctx.chapters.get(resolved)
        if anchor:
            return f"[{text}](#{fragment or anchor})"

        # `modules/` (lien vers le dossier des modules) et manifeste
        # manual_order_*.txt : pas d'équivalent dans le PDF, on garde le
        # texte sans lien.
        if path_part.rstrip("/") == "modules" or (
            "manual_order_" in path_part and path_part.endswith(".txt")
        ):
            return f"`{text}`" if not text.startswith("`") else text

        inside_docs = os.path.commonpath([resolved, ctx.src_dir]) == ctx.src_dir
        inside_repo = os.path.commonpath([resolved, ctx.repo_root]) == ctx.repo_root

        if not os.path.exists(resolved):
            ctx.error(src_path, line,
                      f"lien cassé [{text}]({target}) : fichier introuvable")
            return match.group(0)

        if inside_docs and resolved.endswith(".md"):
            ctx.error(src_path, line,
                      f"lien [{text}]({target}) vers un chapitre absent du "
                      f"manifeste du manuel")
            return match.group(0)

        if not inside_repo:
            ctx.error(src_path, line,
                      f"lien [{text}]({target}) hors du dépôt")
            return match.group(0)

        # Fichier ou dossier du dépôt hors manuel : URL publique.
        return f"[{text}]({repo_url_for(ctx, resolved, fragment)})"

    # Regex : [texte](cible) où cible ne commence pas par # (déjà une ancre)
    # et n'est pas vide. On capture text+target.
    pattern = re.compile(r'\[([^\]]+)\]\(([^)#][^)]*)\)')
    return pattern.sub(replace, content)


def convert_pdf_page_breaks(content):
    """Convert hidden source markers into LaTeX page breaks.

    The HTML comment stays invisible in GitHub-rendered Markdown. Only the
    transient PDF copy receives ``\\newpage``, which keeps long code examples
    together without leaking PDF-specific syntax into the public sources.
    """
    return re.sub(
        r'^[ \t]*<!-- pdf-page-break -->[ \t]*$',
        r'\\newpage',
        content,
        flags=re.MULTILINE,
    )


# ----------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------

def process_file(src_path, dst_path, ctx):
    """Lit src_path, applique toutes les transformations, écrit dst_path."""
    with open(src_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Étape 1 : strip les toggles de langue (1ère ligne typiquement)
    content = strip_language_toggle(content)

    # Étape 2 : transformer les liens. Avant toute étape qui déplace des
    # lignes, pour que les diagnostics donnent la ligne du fichier source.
    content = transform_internal_links(content, src_path, ctx)

    # Étape 3 : injecter l'ID au H1 des chapitres du manuel
    anchor = ctx.chapters.get(src_path)
    if anchor:
        content = inject_h1_id(content, anchor)

    # Étape 4 : convertir les ancres HTML stables des sources en attributs
    # de titre Pandoc, afin qu'elles deviennent aussi des labels LaTeX.
    content = convert_html_anchors_to_heading_ids(content)

    # (L'étape « corriger les valeurs obsolètes » a été retirée : le
    # Markdown source est la seule source de vérité ; on ne masque
    # plus de valeurs périmées à la génération PDF.)

    # Étape 5 : convertir les marqueurs invisibles de saut de page
    content = convert_pdf_page_breaks(content)

    # Écrire le résultat
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    with open(dst_path, "w", encoding="utf-8") as f:
        f.write(content)


def process_directory(src_dir, dst_dir, order_file=None):
    """Traite récursivement tous les .md de src_dir vers dst_dir.

    Retourne le nombre d'erreurs ; le dossier de sortie est écrit même en
    cas d'erreur, pour inspection.
    """
    # realpath partout : le dossier source et le manifeste doivent désigner
    # les chapitres par exactement les mêmes chemins.
    src = Path(os.path.realpath(src_dir))
    dst = Path(dst_dir)

    if not src.is_dir():
        sys.stderr.write(f"error: {src_dir} is not a directory\n")
        return 1

    if order_file is None:
        order_file = src.parent / f"manual_order_{src.name}.txt"
    order_file = os.path.realpath(order_file)
    if not os.path.isfile(order_file):
        sys.stderr.write(f"error: order file not found: {order_file}\n")
        return 1

    repo_root, chapters, problems = load_chapters(str(src), order_file)
    ctx = LinkContext(str(src), repo_root, chapters)
    ctx.errors.extend(problems)

    # Nettoyer le dossier de destination s'il existe
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)

    md_files = sorted(src.rglob("*.md"))
    if not md_files:
        sys.stderr.write(f"error: no .md files found in {src_dir}\n")
        return 1

    print(f"preprocess_pdf: {src_dir} -> {dst_dir} ({len(md_files)} files)",
          flush=True)

    for src_file in md_files:
        src_file = str(src_file)
        # Un .md hors manifeste n'apparaîtrait pas dans le PDF sans que
        # personne ne le remarque : c'est une erreur, pas un avertissement.
        if src_file not in chapters:
            ctx.error(src_file, 1,
                      "fichier absent du manifeste "
                      f"{os.path.basename(order_file)} : ce chapitre "
                      "manquerait dans le PDF")
        dst_file = str(dst / os.path.relpath(src_file, str(src)))
        process_file(src_file, dst_file, ctx)

    if ctx.errors:
        for message in ctx.errors:
            sys.stderr.write(f"  error: {message}\n")
        sys.stderr.write(
            f"preprocess_pdf: {len(ctx.errors)} error(s), PDF not generated.\n"
        )
        return len(ctx.errors)

    print("preprocess_pdf: done.")
    return 0


def main():
    if len(sys.argv) not in (3, 4):
        sys.stderr.write(__doc__)
        sys.exit(1)

    order_file = sys.argv[3] if len(sys.argv) == 4 else None
    errors = process_directory(sys.argv[1], sys.argv[2], order_file)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
