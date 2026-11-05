# Generador del diagrama

`python3 docs/diagram/gen_diagram.py docs/architecture.svg` regenera el SVG con los íconos oficiales de Azure.
Requiere la biblioteca de íconos en `~/Microsoft/demoarc/assets/azure-icons/Azure_Public_Service_Icons/Icons/`
(descarga: https://learn.microsoft.com/azure/architecture/icons/). Para ver el resultado en PNG:
`"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --screenshot=arch.png --window-size=1400,1380 file://$PWD/docs/architecture.svg`.
