import nextCoreWebVitals from "eslint-config-next/core-web-vitals";
import nextTypescript from "eslint-config-next/typescript";

// Both entry points are needed: core-web-vitals alone carries no TypeScript rules (see stablelp-ui).
const config = [
  { ignores: ["node_modules/", ".next/", "coverage/"] },
  ...nextCoreWebVitals,
  ...nextTypescript,
  {
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", caughtErrorsIgnorePattern: "^_", ignoreRestSiblings: true },
      ],
      // An effect arrow with an expression body returns that value to React as its cleanup.
      "no-restricted-syntax": [
        "error",
        {
          selector:
            "CallExpression[callee.name=/^use(Layout|Insertion)?Effect$/] > ArrowFunctionExpression.arguments:first-child[expression=true][body.type!='ArrowFunctionExpression']",
          message: "Effect callback with an expression body: its value becomes the cleanup. Use a block body.",
        },
      ],
    },
  },
];

export default config;
