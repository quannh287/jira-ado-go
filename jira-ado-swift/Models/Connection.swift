import Foundation

/// Everything a sync needs to reach Jira and ADO, read from settings and the keychain.
struct Connection {
    var adoOrg = "", pat = ""
    var jiraURL = "", jiraEmail = "", jiraToken = ""
    var jqlExtra = ""  // ANDed into every search
    var jiraKeyField = ""  // ADO field holding "KEY - id"
    var rules = Rules()

    /// The first setting a sync can't run without, or nil.
    var missing: String? {
        if adoOrg.isEmpty { return "ADO organization" }
        if pat.isEmpty { return "ADO PAT" }
        if jiraURL.isEmpty { return "Jira URL" }
        if jiraEmail.isEmpty { return "Jira email" }
        if jiraToken.isEmpty { return "Jira API token" }
        return nil
    }
}
