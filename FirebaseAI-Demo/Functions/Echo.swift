//
//  Echo.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import FirebaseAILogic

func echo(input: String) -> JSONObject {
    return ["output": .string(input)]
}

let echoTool = FunctionDeclaration(
  name: "echo",
  description: "Returns the exact input string back to the caller.",
  parameters: [
    "input": .string(description: "The string to echo back."),
  ]
)
