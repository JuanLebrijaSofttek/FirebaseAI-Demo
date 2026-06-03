//
//  Logic.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import FirebaseAILogic
import SwiftUI

class FirebaseAIVM {
    private var streamedText: String = ""
    
    var history = [
        ModelContent(role: "user", parts: "Hello, I have 2 dogs in my house."),
        ModelContent(role: "model", parts: "Great to meet you. What would you like to know?"),
    ]
    
    let model = FirebaseAI.firebaseAI(backend: .vertexAI(location: "global")).generativeModel(
      modelName: "gemini-3.5-flash",
      tools: [.functionDeclarations([fetchWeatherTool])]
    )
    
    func sendMessageStream() async {
        // Initialize the chat with optional chat history
        let chat = model.startChat(history: history)
        
        print("🎏 Sending message...")
        
        do{
            // To stream generated text output, call sendMessageStream and pass in the message
            let contentStream = try chat.sendMessageStream("How many paws are in my house?")
            for try await chunk in contentStream {
                if let text = chunk.text {
                    print(text)
                    streamedText.append(text)
                }
            }
        } catch let error {
            print(error.localizedDescription)
        }
        print("🎏 Message: \(streamedText)")
    }
    
    func sendMessageFunctions() async {
        let chat = model.startChat()
        let prompt = "What was the weather in Boston on October 17, 2024?"

        do{
            // Send the user's question (the prompt) to the model using multi-turn chat.
            let response = try await chat.sendMessage(prompt)

            var functionResponses = [FunctionResponsePart]()

            // When the model responds with one or more function calls, invoke the function(s).
            for functionCall in response.functionCalls {
              if functionCall.name == "fetchWeather" {
                // TODO(developer): Handle invalid arguments.
                guard case let .object(location) = functionCall.args["location"] else { fatalError() }
                guard case let .string(city) = location["city"] else { fatalError() }
                guard case let .string(state) = location["state"] else { fatalError() }
                guard case let .string(date) = functionCall.args["date"] else { fatalError() }

                functionResponses.append(FunctionResponsePart(
                  name: functionCall.name,
                  // Forward the structured input data prepared by the model
                  // to the hypothetical external API.
                  response: fetchWeather(city: city, state: state, date: date)
                ))
              }
              // TODO(developer): Handle other potential function calls, if any.
            }
            
            // Send the response(s) from the function back to the model
            // so that the model can use it to generate its final response.
            let finalResponse = try await chat.sendMessage(
              [ModelContent(role: "function", parts: functionResponses)]
            )

            // Log the text response.
            print("🎏 Message: \(finalResponse.text ?? "No text in response.")")
        } catch let error {
            print(error.localizedDescription)
        }
    }
}
