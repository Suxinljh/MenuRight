import Foundation

/// Sample documents for the settings preview.
///
/// One per language, deliberately short (a screenful at most) and written to
/// exercise the token kinds the theme defines: comment, keyword, type,
/// function, string, number. They are product sample code, not user content.
enum CodePreviewSamples {
    static func source(for language: CodeLanguage) -> String {
        samples[language] ?? samples[.plainText]!
    }

    /// File name shown above the preview card. It is also what
    /// `CodeLanguage.detect(fileName:)` would resolve back to the same
    /// language — `CodeHighlightTests` asserts that round trip.
    static func fileName(for language: CodeLanguage) -> String {
        fileNames[language] ?? "sample.txt"
    }

    private static let fileNames: [CodeLanguage: String] = [
        .swift: "Greeting.swift",
        .python: "greeting.py",
        .javascript: "greeting.js",
        .typescript: "greeting.ts",
        .html: "greeting.html",
        .css: "greeting.css",
        .json: "greeting.json",
        .yaml: "greeting.yaml",
        .markdown: "README.md",
        .shell: "greeting.sh",
        .sql: "greeting.sql",
        .c: "greeting.c",
        .cpp: "greeting.cpp",
        .go: "greeting.go",
        .rust: "greeting.rs",
        .java: "Greeting.java",
        .plainText: "sample.txt",
    ]

    private static let samples: [CodeLanguage: String] = [
        .swift: """
        // MenuRight code preview
        import Foundation

        struct Greeting {
            let count: Int = 42

            func hello(name: String) -> String {
                return "Hello, \\(name)!"
            }
        }
        """,

        .python: """
        # MenuRight code preview
        from dataclasses import dataclass


        @dataclass
        class Greeting:
            count: int = 42

            def hello(self, name: str) -> str:
                \"\"\"Return a greeting.\"\"\"
                return f"Hello, {name}!"
        """,

        .javascript: """
        // MenuRight code preview
        const greetings = ["hello", "hi"];
        const started = new Date();

        function hello(name = "world") {
          const count = 42;
          return `Hello, ${name}! (${count})`;
        }
        """,

        .typescript: """
        // MenuRight code preview
        interface Greeting {
          name: string;
          count: number;
        }

        function hello(greeting: Greeting): string {
          const count = 42;
          return `Hello, ${greeting.name}! (${count})`;
        }
        """,

        .html: """
        <!-- MenuRight code preview -->
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <title>MenuRight</title>
          </head>
          <body>
            <h1 class="title">Hello</h1>
          </body>
        </html>
        """,

        .css: """
        /* MenuRight code preview */
        :root {
          --accent: #3b82f6;
        }

        .title {
          font-size: 24px;
          color: var(--accent);
          background: url("grid.png");
        }
        """,

        .json: """
        {
          "name": "MenuRight",
          "version": 2,
          "enabled": true,
          "features": ["preview", "theme"]
        }
        """,

        .yaml: """
        # MenuRight code preview
        name: MenuRight
        version: 2
        enabled: true
        url: "https://example.com"
        features:
          - preview
          - theme
        """,

        .markdown: """
        # MenuRight

        Code preview with **syntax highlighting**.

        - `space` opens the preview
        - themes come from Settings

        [Documentation](https://example.com)
        """,

        .shell: """
        #!/bin/bash
        # MenuRight code preview
        set -euo pipefail

        name="world"
        home=$HOME
        for i in 1 2 3; do
          echo "Hello, ${name} #$i"
        done
        """,

        .sql: """
        -- MenuRight code preview
        SELECT id, name
        FROM users
        WHERE name = 'world' AND active = true
        ORDER BY name ASC
        LIMIT 10;
        """,

        .c: """
        /* MenuRight code preview */
        #include <stdio.h>

        int main(void) {
            const char *name = "world";
            printf("Hello, %s!\\n", name);
            return 0;
        }
        """,

        .cpp: """
        // MenuRight code preview
        #include <string>

        class Greeting {
        public:
            explicit Greeting(std::string name) : name_(std::move(name)) {}

            std::string hello() const {
                return "Hello, " + name_ + "!";
            }

        private:
            std::string name_;
        };
        """,

        .go: """
        // MenuRight code preview
        package main

        import "fmt"

        func main() {
        \tname := "world"
        \tvar count int = 42
        \tfmt.Printf("Hello, %s! (%d)\\n", name, count)
        }
        """,

        .rust: """
        // MenuRight code preview
        struct Greeting {
            count: u32,
        }

        fn hello(name: &str) -> String {
            let count = 42;
            format!("Hello, {}! ({})", name, count)
        }
        """,

        .java: """
        // MenuRight code preview
        public class Greeting {
            private final int count = 42;

            public String hello(String name) {
                return "Hello, " + name + "!";
            }
        }
        """,

        .plainText: """
        MenuRight code preview

        This file type has no highlighter, so it is shown as plain text.
        """,
    ]
}
