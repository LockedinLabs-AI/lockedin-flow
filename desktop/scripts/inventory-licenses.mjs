import parse from "spdx-expression-parse";

// SPDX operators are case-sensitive even though the parser is more permissive.
export function assertLicenseExpression(expression) {
  if (
    typeof expression !== "string" ||
    !expression.trim() ||
    expression.length > 1024 ||
    /[\r\n\x00-\x1f\x7f]/.test(expression) ||
    expression.includes("/") ||
    expression.split(/[\s()]+/).some((token) =>
      /^(and|or|with)$/i.test(token) && token !== token.toUpperCase())
  ) throw new Error("Invalid inventory license expression.");
  try {
    return parse(expression);
  } catch {
    // Upstream metadata must not be reflected into public diagnostic output.
    throw new Error("Invalid inventory license expression.");
  }
}

export function cargoLicenseExpression(declaration) {
  if (typeof declaration !== "string")
    throw new Error("Missing Cargo license declaration.");
  if (declaration.length > 1024 || /[\r\n\x00-\x1f\x7f]/.test(declaration))
    throw new Error("Invalid Cargo license declaration.");
  let expression = declaration.trim();
  if (expression.includes("/")) {
    // Cargo's deprecated slash-separated alternatives predate SPDX OR.
    // Only translate a simple list; never guess precedence in mixed syntax.
    if (!/^(?:[A-Za-z0-9][A-Za-z0-9.+-]*\s*\/\s*)+[A-Za-z0-9][A-Za-z0-9.+-]*$/.test(expression))
      throw new Error("Ambiguous legacy Cargo license declaration.");
    expression = expression.split("/").map((part) => part.trim()).join(" OR ");
  }
  assertLicenseExpression(expression);
  return expression;
}

export function assertInventoryLicenses(sbom) {
  for (const component of [sbom.metadata?.component, ...(sbom.components ?? [])]) {
    if (!component || !Array.isArray(component.licenses) || !component.licenses.length)
      throw new Error("Missing component license.");
    const expressions = component.licenses.filter((choice) => choice.expression !== undefined);
    if (expressions.length && component.licenses.length !== 1)
      throw new Error("An inventory license expression must be a single choice.");
    for (const choice of component.licenses) {
      if (choice.expression !== undefined) {
        if (choice.license !== undefined)
          throw new Error("Ambiguous inventory license choice.");
        assertLicenseExpression(choice.expression);
      } else {
        const id = choice.license?.id;
        const parsed = assertLicenseExpression(id);
        if (parsed.license !== id || parsed.exception || parsed.plus || parsed.conjunction)
          throw new Error("An inventory license ID must identify one license.");
      }
    }
  }
}
