import Foundation

/// Links to GitHub documentation shown by "Learn more" buttons.
enum ExternalLinks {
    /// Environments and plan availability (the plan note, §10).
    static let environmentPlans = URL(
        string: "https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment"
    )
    /// Authorizing a token for an organization that enforces SAML single sign-on (§7.4).
    static let samlSingleSignOn = URL(
        string: "https://docs.github.com/en/authentication/authenticating-with-single-sign-on/about-authentication-with-single-sign-on"
    )
}
