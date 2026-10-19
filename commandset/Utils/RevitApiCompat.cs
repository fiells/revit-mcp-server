using Autodesk.Revit.DB;

namespace RevitMCPCommandSet.Utils
{
    /// <summary>
    /// Wrappers for Revit API members that were added or replaced in Revit 2022.
    /// On 2022+ they compile to the native call; on 2019-2021 they use the older equivalent.
    /// </summary>
    public static class RevitApiCompat
    {
        /// <summary>
        /// Gets the ids of the local elements referenced by a tag.
        /// Revit 2022 added multi-reference tags; earlier versions expose a single TaggedLocalElementId.
        /// </summary>
        public static ICollection<ElementId> GetTaggedIds(this IndependentTag tag)
        {
#if REVIT2022_OR_GREATER
            return tag.GetTaggedLocalElementIds();
#else
            var id = tag.TaggedLocalElementId;
            return id == null || id == ElementId.InvalidElementId
                ? new List<ElementId>()
                : new List<ElementId> { id };
#endif
        }

        /// <summary>
        /// Gets the data type of a parameter definition: the spec TypeId on Revit 2022+
        /// (e.g. "autodesk.spec.aec:length-2.0.0"), the ParameterType name on earlier versions (e.g. "Length").
        /// </summary>
        public static string GetDataTypeName(this Definition definition)
        {
#if REVIT2022_OR_GREATER
            return definition.GetDataType()?.TypeId;
#else
            return definition.ParameterType.ToString();
#endif
        }

        /// <summary>
        /// Gets the properties-panel group of a parameter definition: the GroupTypeId TypeId on Revit 2022+,
        /// the BuiltInParameterGroup name on earlier versions (e.g. "PG_DATA").
        /// </summary>
        public static string GetGroupName(this Definition definition)
        {
#if REVIT2022_OR_GREATER
            return definition.GetGroupTypeId()?.TypeId;
#else
            return definition.ParameterGroup.ToString();
#endif
        }

        /// <summary>
        /// Creates a floor from a single boundary loop. Floor.Create was added in Revit 2022;
        /// earlier versions use Document.Create.NewFloor, which takes one boundary without openings.
        /// </summary>
        public static Floor CreateFloor(Document doc, IList<CurveLoop> profile, ElementId floorTypeId, ElementId levelId)
        {
#if REVIT2022_OR_GREATER
            return Floor.Create(doc, profile, floorTypeId, levelId);
#else
            if (profile.Count != 1)
                throw new NotSupportedException("Floors with openings require Revit 2022 or newer.");

            var curves = new CurveArray();
            foreach (Curve curve in profile[0])
                curves.Append(curve);

            var floorType = (FloorType)doc.GetElement(floorTypeId);
            var level = (Level)doc.GetElement(levelId);
            return doc.Create.NewFloor(curves, floorType, level, false);
#endif
        }

        /// <summary>
        /// Creates a ceiling. The Revit API has no way to create ceilings before Revit 2022.
        /// </summary>
        public static Ceiling CreateCeiling(Document doc, IList<CurveLoop> profile, ElementId ceilingTypeId, ElementId levelId)
        {
#if REVIT2022_OR_GREATER
            return Ceiling.Create(doc, profile, ceilingTypeId, levelId);
#else
            throw new NotSupportedException("Creating ceilings requires Revit 2022 or newer.");
#endif
        }
    }
}
