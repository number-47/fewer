#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEMPLATES="${ROOT}/Resources/Templates"

for file in PlainText.txt Markdown.md WordDocument.docx ExcelWorkbook.xlsx PowerPointPresentation.pptx JSON.json CSV.csv; do
  test -f "${TEMPLATES}/${file}"
done

/usr/bin/unzip -tqq "${TEMPLATES}/WordDocument.docx"
/usr/bin/unzip -tqq "${TEMPLATES}/ExcelWorkbook.xlsx"
/usr/bin/unzip -tqq "${TEMPLATES}/PowerPointPresentation.pptx"

/usr/bin/unzip -l "${TEMPLATES}/WordDocument.docx" | /usr/bin/grep -q 'word/document.xml'
/usr/bin/unzip -l "${TEMPLATES}/ExcelWorkbook.xlsx" | /usr/bin/grep -q 'xl/workbook.xml'
/usr/bin/unzip -l "${TEMPLATES}/PowerPointPresentation.pptx" | /usr/bin/grep -q 'ppt/presentation.xml'

/usr/bin/plutil -lint "${ROOT}/FewerApp/Info.plist" >/dev/null
echo "Template verification passed"
