package syncjob

import "slices"

// ADO fields the sync can write and the Jira field each one is built from (transforms live in internal/syncer).
// A job's Mappings select which of these are written; Title, area, iteration and the Jira key field are always written.
const (
	FieldTitle            = "System.Title"
	FieldDescription      = "System.Description"
	FieldState            = "System.State"
	FieldPriority         = "Microsoft.VSTS.Common.Priority"
	FieldAssignedTo       = "System.AssignedTo"
	FieldCreatedBy        = "System.CreatedBy"
	FieldStartDate        = "Microsoft.VSTS.Scheduling.StartDate"
	FieldTargetDate       = "Microsoft.VSTS.Scheduling.TargetDate"
	FieldOriginalEstimate = "Microsoft.VSTS.Scheduling.OriginalEstimate"
	FieldRemainingWork    = "Microsoft.VSTS.Scheduling.RemainingWork"
	FieldCompletedWork    = "Microsoft.VSTS.Scheduling.CompletedWork"
)

// Supported lists every pair the engine knows, in the source app's order.
var Supported = []FieldPair{
	{"summary", FieldTitle},
	{"description", FieldDescription},
	{"status", FieldState},
	{"priority", FieldPriority},
	{"assignee", FieldAssignedTo},
	{"reporter", FieldCreatedBy},
	{"created", FieldStartDate},
	{"duedate", FieldTargetDate},
	{"aggregatetimeoriginalestimate", FieldOriginalEstimate},
	{"aggregatetimeestimate", FieldRemainingWork},
	{"aggregatetimespent", FieldCompletedWork},
}

// SmartDefaults is every supported pair — what the source app always wrote.
func SmartDefaults() []FieldPair { return slices.Clone(Supported) }

func IsSupported(p FieldPair) bool { return slices.Contains(Supported, p) }

func (p FieldPair) Label() string { return p.Jira + " → " + p.ADO }

// Writes reports whether the job maps adoField; Title is always written.
func (j Job) Writes(adoField string) bool {
	return adoField == FieldTitle || slices.ContainsFunc(j.Mappings, func(m FieldPair) bool { return m.ADO == adoField })
}
