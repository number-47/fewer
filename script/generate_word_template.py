from pathlib import Path

from docx import Document


repository = Path(__file__).resolve().parent.parent
output = repository / "Resources" / "Templates" / "WordDocument.docx"
output.parent.mkdir(parents=True, exist_ok=True)
Document().save(output)
