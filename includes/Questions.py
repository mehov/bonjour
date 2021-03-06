class Questions:

    def __init__(self):
        self.questions = {}

    def ask(self, key, prompt, default):
        answer = input(prompt)
        self.questions[key] = {"prompt": prompt, "default": default, "answer": answer}
        return answer

    def answer(self, key):
        return self.questions[key]['answer']
