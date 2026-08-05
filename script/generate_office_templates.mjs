import fs from "node:fs/promises";
import path from "node:path";
import { Presentation, PresentationFile, SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const root = process.cwd();
const outputDirectory = path.join(root, "Resources", "Templates");
const qaDirectory = path.join(root, ".build", "office-template-qa");

await fs.mkdir(outputDirectory, { recursive: true });
await fs.mkdir(qaDirectory, { recursive: true });

const workbook = Workbook.create();
workbook.worksheets.add("Sheet1");
const workbookPreview = await workbook.render({
  sheetName: "Sheet1",
  range: "A1:D12",
  scale: 2,
  format: "png",
});
await fs.writeFile(
  path.join(qaDirectory, "ExcelWorkbook.png"),
  new Uint8Array(await workbookPreview.arrayBuffer()),
);
const xlsx = await SpreadsheetFile.exportXlsx(workbook);
await xlsx.save(path.join(outputDirectory, "ExcelWorkbook.xlsx"));

const presentation = Presentation.create({
  slideSize: { width: 1280, height: 720 },
});
const slide = presentation.slides.add();
slide.background.fill = "#FFFFFF";
const slidePreview = await presentation.export({ slide, format: "png", scale: 1 });
await fs.writeFile(
  path.join(qaDirectory, "PowerPointPresentation.png"),
  new Uint8Array(await slidePreview.arrayBuffer()),
);
const pptx = await PresentationFile.exportPptx(presentation);
await pptx.save(path.join(outputDirectory, "PowerPointPresentation.pptx"));
