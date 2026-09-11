# Diagrams

Mermaid sources for the flowcharts in the README and docs/AI.md, rendered to PNG so they show in every markdown viewer, the GitHub mobile app included. Each diagram has a light and a dark render; the docs use a `<picture>` element so GitHub serves the one matching the reader's theme.

Re-render after editing a `.mmd` file:

```bash
cd docs/diagrams
for f in *.mmd; do n=${f%.mmd}
  npx -y -p @mermaid-js/mermaid-cli mmdc -q -i $f -o $n-light.png -c mermaid-light.json -b white -s 3
  npx -y -p @mermaid-js/mermaid-cli mmdc -q -i $f -o $n-dark.png -c mermaid-dark.json -b '#0d1117' -s 3
done
```

Renders are 3x. The GitHub mobile app ignores the `width` attribute and scales every image to the column, so the four vertical diagrams are padded to a 1500 px canvas after rendering; the diagram then takes about half the phone column instead of all of it. Pad after re-rendering:

```bash
for f in ai-levels level1-copy-paste level2-connected level4-phone; do
  h=$(sips -g pixelHeight $f-light.png | awk '/pixel/{print $2}')
  sips --padToHeightWidth $h 1500 --padColor FFFFFF $f-light.png
  sips --padToHeightWidth $h 1500 --padColor 0D1117 $f-dark.png
done
```

The docs display the padded diagrams at `width="500"` (a third of the canvas) and the wide Level 3 diagram at a third of its pixel width.
