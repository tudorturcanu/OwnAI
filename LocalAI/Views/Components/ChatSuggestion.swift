import Foundation

struct ChatSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let prompt: String
    /// Templates that need the user's own content should populate the composer
    /// instead of spending a message on an incomplete request.
    var requiresInput = false
}

enum ChatSuggestions {
    /// A large pool of suggestions. A handful are drawn at random each time
    /// the empty state appears so returning users see fresh prompts instead
    /// of the same static row every time.
    static let pool: [ChatSuggestion] = [
        ChatSuggestion(icon: "lightbulb.fill", title: String(localized: "Tell me"), subtitle: String(localized: "something fascinating"), prompt: String(localized: "Tell me something fascinating")),
        ChatSuggestion(icon: "atom", title: String(localized: "Explain"), subtitle: String(localized: "complex topics simply"), prompt: String(localized: "Explain a complex topic like black holes simply")),
        ChatSuggestion(icon: "pencil.line", title: String(localized: "Write"), subtitle: String(localized: "an email or story"), prompt: String(localized: "Write a short creative story about a robot")),
        ChatSuggestion(icon: "book.fill", title: String(localized: "Discover"), subtitle: String(localized: "my next book"), prompt: String(localized: "Help me discover my next book")),
        ChatSuggestion(icon: "map.fill", title: String(localized: "Plan"), subtitle: String(localized: "my weekend trip"), prompt: String(localized: "Help me plan a relaxing weekend trip")),
        ChatSuggestion(icon: "bolt.fill", title: String(localized: "Boost"), subtitle: String(localized: "my productivity"), prompt: String(localized: "How can I boost my productivity?")),
        ChatSuggestion(icon: "ladybug.fill", title: String(localized: "Debug"), subtitle: String(localized: "my code snippet"), prompt: String(localized: "Help me debug this Swift code snippet:\n"), requiresInput: true),
        ChatSuggestion(icon: "brain.head.profile", title: String(localized: "Quiz"), subtitle: String(localized: "me on trivia"), prompt: String(localized: "Quiz me on random trivia, one question at a time")),
        ChatSuggestion(icon: "fork.knife", title: String(localized: "Suggest"), subtitle: String(localized: "a recipe idea"), prompt: String(localized: "Suggest a quick and healthy dinner recipe")),
        ChatSuggestion(icon: "figure.strengthtraining.traditional", title: String(localized: "Build"), subtitle: String(localized: "a workout plan"), prompt: String(localized: "Build me a simple weekly workout plan")),
        ChatSuggestion(icon: "dollarsign.circle.fill", title: String(localized: "Help"), subtitle: String(localized: "budget my money"), prompt: String(localized: "Help me create a simple monthly budget")),
        ChatSuggestion(icon: "briefcase.fill", title: String(localized: "Draft"), subtitle: String(localized: "a cover letter"), prompt: String(localized: "Draft a short cover letter for a job application")),
        ChatSuggestion(icon: "message.fill", title: String(localized: "Practice"), subtitle: String(localized: "a difficult conversation"), prompt: String(localized: "Help me practice a difficult conversation with a coworker")),
        ChatSuggestion(icon: "globe", title: String(localized: "Teach"), subtitle: String(localized: "me a new language"), prompt: String(localized: "Teach me some basic phrases in a new language")),
        ChatSuggestion(icon: "theatermasks.fill", title: String(localized: "Tell"), subtitle: String(localized: "me a joke"), prompt: String(localized: "Tell me a clever joke")),
        ChatSuggestion(icon: "text.book.closed.fill", title: String(localized: "Summarize"), subtitle: String(localized: "a topic for me"), prompt: String(localized: "Summarize the history of the internet in a few paragraphs")),
        ChatSuggestion(icon: "brain", title: String(localized: "Brainstorm"), subtitle: String(localized: "business ideas"), prompt: String(localized: "Brainstorm some creative small business ideas")),
        ChatSuggestion(icon: "gift.fill", title: String(localized: "Suggest"), subtitle: String(localized: "a gift idea"), prompt: String(localized: "Suggest a thoughtful gift idea for a close friend")),
        ChatSuggestion(icon: "leaf.fill", title: String(localized: "Give"), subtitle: String(localized: "wellness tips"), prompt: String(localized: "Give me some simple tips to reduce stress")),
        ChatSuggestion(icon: "paintpalette.fill", title: String(localized: "Inspire"), subtitle: String(localized: "a creative project"), prompt: String(localized: "Inspire me with ideas for a creative art project")),
        ChatSuggestion(icon: "calendar", title: String(localized: "Organize"), subtitle: String(localized: "my daily schedule"), prompt: String(localized: "Help me organize a productive daily schedule")),
        ChatSuggestion(icon: "sparkles", title: String(localized: "Surprise"), subtitle: String(localized: "me with something fun"), prompt: String(localized: "Surprise me with something fun to think about")),
        ChatSuggestion(icon: "graduationcap.fill", title: String(localized: "Explain"), subtitle: String(localized: "a school subject"), prompt: String(localized: "Explain photosynthesis like I'm in middle school")),
        ChatSuggestion(icon: "airplane", title: String(localized: "Recommend"), subtitle: String(localized: "a travel destination"), prompt: String(localized: "Recommend a travel destination based on my interests")),
        ChatSuggestion(icon: "heart.text.square.fill", title: String(localized: "Write"), subtitle: String(localized: "a heartfelt message"), prompt: String(localized: "Help me write a heartfelt thank-you message")),
        ChatSuggestion(icon: "chart.bar.fill", title: String(localized: "Analyze"), subtitle: String(localized: "a tricky decision"), prompt: String(localized: "Help me weigh the pros and cons of a tough decision")),
        ChatSuggestion(icon: "person.2.fill", title: String(localized: "Give"), subtitle: String(localized: "relationship advice"), prompt: String(localized: "Give me some advice on maintaining a long-distance friendship")),
        ChatSuggestion(icon: "wrench.and.screwdriver.fill", title: String(localized: "Walk me"), subtitle: String(localized: "through a DIY fix"), prompt: String(localized: "Walk me through fixing a common household problem")),
        ChatSuggestion(icon: "chevron.left.forwardslash.chevron.right", title: String(localized: "Explain"), subtitle: String(localized: "a coding concept"), prompt: String(localized: "Explain how recursion works with a simple example")),
        ChatSuggestion(icon: "film.fill", title: String(localized: "Recommend"), subtitle: String(localized: "a movie to watch"), prompt: String(localized: "Recommend a movie based on my mood")),
        ChatSuggestion(icon: "questionmark.circle.fill", title: String(localized: "Ask me"), subtitle: String(localized: "would you rather"), prompt: String(localized: "Play a game of would-you-rather with me")),
        ChatSuggestion(icon: "text.quote", title: String(localized: "Share"), subtitle: String(localized: "an inspiring quote"), prompt: String(localized: "Share an inspiring quote and explain its meaning")),
        ChatSuggestion(icon: "puzzlepiece.extension.fill", title: String(localized: "Give"), subtitle: String(localized: "me a riddle"), prompt: String(localized: "Give me a tricky riddle to solve")),
        ChatSuggestion(icon: "house.fill", title: String(localized: "Suggest"), subtitle: String(localized: "home organization tips"), prompt: String(localized: "Suggest ways to organize a small living space")),
        ChatSuggestion(icon: "cloud.sun.fill", title: String(localized: "Explain"), subtitle: String(localized: "a science phenomenon"), prompt: String(localized: "Explain why the sky is blue")),
        ChatSuggestion(icon: "hands.sparkles.fill", title: String(localized: "Guide"), subtitle: String(localized: "a short meditation"), prompt: String(localized: "Guide me through a short breathing meditation")),
        ChatSuggestion(icon: "text.badge.checkmark", title: String(localized: "Proofread"), subtitle: String(localized: "my writing"), prompt: String(localized: "Proofread and improve this paragraph:\n"), requiresInput: true),
        ChatSuggestion(icon: "curlybraces", title: String(localized: "Convert"), subtitle: String(localized: "code between languages"), prompt: String(localized: "Convert this code snippet to Python:\n"), requiresInput: true),
    ]
}
