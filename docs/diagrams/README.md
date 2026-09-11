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

Renders are 3x; the docs display them at half the pixel width, the same rule as the screenshots.
