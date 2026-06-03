//
//  FetchWeather.swift
//  FirebaseAI-Demo
//
//  Created by Juan Ignacio Lebrija Muraira on 02/06/26.
//

import FirebaseAILogic

// This function calls a hypothetical external API that returns
// a collection of weather information for a given location on a given date.
func fetchWeather(city: String, state: String, date: String) -> JSONObject {

  // TODO(developer): Write a standard function that would call an external weather API.

  // For demo purposes, this hypothetical response is hardcoded here in the expected format.
  return [
    "temperature": .number(38),
    "chancePrecipitation": .string("56%"),
    "cloudConditions": .string("partlyCloudy"),
  ]
}

let fetchWeatherTool = FunctionDeclaration(
  name: "fetchWeather",
  description: "Get the weather conditions for a specific city on a specific date.",
  parameters: [
    "location": .object(
      properties: [
        "city": .string(description: "The city of the location."),
        "state": .string(description: "The US state of the location."),
      ],
      description: """
      The name of the city and its state for which to get the weather. Only cities in the
      USA are supported.
      """
    ),
    "date": .string(
      description: """
      The date for which to get the weather. Date must be in the format: YYYY-MM-DD.
      """
    ),
  ]
)
