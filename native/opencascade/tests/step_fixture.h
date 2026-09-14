#pragma once
#include <BRepPrimAPI_MakeBox.hxx>
#include <Quantity_ColorRGBA.hxx>
#include <STEPCAFControl_Writer.hxx>
#include <STEPConstruct_ExternRefs.hxx>
#include <StepBasic_ProductDefinition.hxx>
#include <StepData_StepModel.hxx>
#include <TDataStd_Name.hxx>
#include <TDocStd_Document.hxx>
#include <XCAFDoc_ColorTool.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <sstream>
#include <stdexcept>
inline std::string step_fixture(bool color = true, int mode = 0,
                                bool meter = false, bool transparent = false,
                                bool alternate_color = false) {
  occ::handle<TDocStd_Document> doc = new TDocStd_Document("BinXCAF");
  XCAFDoc_DocumentTool::SetLengthUnit(doc, 0.001);
  auto tool = XCAFDoc_DocumentTool::ShapeTool(doc->Main());
  auto root = tool->AddShape(BRepPrimAPI_MakeBox(10, 20, 30).Shape(), false);
  TDataStd_Name::Set(root, TCollection_ExtendedString(u8"Peça única", true));
  if (color)
    XCAFDoc_DocumentTool::ColorTool(doc->Main())
        ->SetColor(root,
                   Quantity_ColorRGBA(
                       alternate_color
                           ? Quantity_Color(0.75, 0.125, 0.5, Quantity_TOC_RGB)
                           : Quantity_Color(0.125, 0.5, 0.75, Quantity_TOC_RGB),
                       transparent ? 0.5f : 1.0f),
                   XCAFDoc_ColorGen);
  if (mode == 1) {
    auto assembly = tool->NewShape();
    tool->AddComponent(assembly, root, TopLoc_Location());
    tool->UpdateAssemblies();
  } else if (mode == 2)
    tool->AddShape(BRepPrimAPI_MakeBox(2, 3, 4).Shape(), false);
  STEPCAFControl_Writer writer;
  writer.SetColorMode(true);
  writer.SetNameMode(true);
  DESTEP_Parameters params;
  params.WriteUnit = meter ? UnitsMethods_LengthUnit_Meter
                           : UnitsMethods_LengthUnit_Millimeter;
  if (!writer.Transfer(doc, params))
    throw std::runtime_error("fixture transfer failed");
  if (mode == 3) {
    auto model = writer.ChangeWriter().Model();
    occ::handle<StepBasic_ProductDefinition> definition;
    for (int i = 1; i <= model->NbEntities(); ++i) {
      definition = occ::down_cast<StepBasic_ProductDefinition>(model->Value(i));
      if (!definition.IsNull())
        break;
    }
    STEPConstruct_ExternRefs refs(writer.ChangeWriter().WS());
    if (definition.IsNull() ||
        !refs.AddExternRef("must-not-open.step", definition, "STEP AP214") ||
        !refs.WriteExternRefs(1))
      throw std::runtime_error("external fixture failed");
  }
  std::ostringstream stream;
  if (writer.WriteStream(stream) != IFSelect_RetDone)
    throw std::runtime_error("fixture stream write failed");
  return stream.str();
}
