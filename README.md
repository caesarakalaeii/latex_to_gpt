# Latex Code Smoother

This code is a Python script that takes in a LaTeX code file containing Bachelor Thesis chapters and uses OpenAI's GPT-3.5 Turbo model to improve the spelling and style of the text. 

## Prerequisites

Before running this code, make sure you have the following:

- Python 3 installed
- OpenAI library installed (`pip install openai`)
- An OpenAI API key, which can be obtained from the OpenAI website

## Setup

1. Clone this repository:

   ```bash
   git clone https://github.com/caesarakalaeii/latex_to_gpt.git
   ```

2. Install the required Python libraries:

   ```bash
   pip install openai
   ```

3. Rename the file `api_secrets_example.py` to `api_secrets.py` and replace `OPENAI_API_KEY` with your own OpenAI API key.

## Usage

1. Place your LaTeX code file in the same directory as the script and name it `latex.txt`.

2. Run the script:

   ```bash
   python smooth_latex.py
   ```

3. The output will be saved in a file named `smoothed_output`.

## Configuration

You can modify the following constants in the code to customize the behavior of the script:

- `MODEL_NAME`: The name of the GPT-3.5 Turbo model to use.
- `TEMP`: The temperature parameter that controls the creativity of the generated text. Higher values (e.g., 0.8) result in more random outputs, while lower values (e.g., 0.2) make the outputs more focused and deterministic.
- `MAX_TOKENS`: The maximum number of tokens to generate. One token roughly equates to 4 characters, so adjust this value based on the desired length of the generated text.
- `INIT_PROMPT`: The initial prompt provided to the GPT-3 model, containing the rules and guidelines for improving the code.
- `RAW_FILE_LOCATION`: The location of the input LaTeX code file.
- `smoothed_output`: The file name for the output with the improved LaTeX code.