import openai
import os
from api_secrets import OPENAI_API_KEY



openai.api_key = OPENAI_API_KEY
MODEL_NAME = 'gpt-3.5-turbo-16k'
TEMP = 0
MAX_TOKENS = 10000
INIT_PROMPT = '''Der Nutzer übergibt dir eine Bachelor Arbeit als Latex Code.
Dies geschieht Kapitel für Kapitel.
Dein Auftrag ist es diesen Code zu überarbeiten, Rechtschreibfehler und Stil zu verbessern.
\\todo anweisungen sind zu entfernen die deren Anweisung wenn möglich umzusetzen.

Dabei Beachte Folgende Regeln:
{1. Passiv vermeiden
2. Sparsam mit adjektiven umgehen
3. Kein Nomilanstil
4. positiv formulieren
5. kein Labojargon verwenden
6. Bestimmter Artikel nur wenn Bezug eindeutig klar ist 
- sonst unbestimmt oder Plural
- unbestimmt einführen oder plural
7. Gegenwart
8. Selbstähnlichkeit
-Übersicht
-Motivation
-Einführung
-Inhalt
-Zusammenfassung
9.Fachbegriffe richig und konstistent verwenden
-Fachbegriff einführen und Konsistent verwenden}'''
RAW_FILE_LOCATION = 'latex.txt'
text = ''
smoothed_text = ''
print('Getting File')
with open(RAW_FILE_LOCATION, 'r') as f:
    text = f.read()
text_split = text.split('\n')
text_part = ''
current_section = ''
print('Smoothing time')
for split in text_split:
    if (split.startswith('\\section') or split.startswith('\\subsection')) and text_part != '':
        print(f'Requesting response for {current_section}')
        prompt = [{'role':'system',
                   'content':INIT_PROMPT},
                  {'role':'user',
                   'content':text_part}]
        response = openai.ChatCompletion.create(
                        model=MODEL_NAME,
                        messages= prompt,
                        max_tokens=MAX_TOKENS,  # maximal amout of tokens, one token roughly equates to 4 chars
                        temperature=TEMP,  # control over creativity
                        n=1, # amount of answers
                        top_p=1,
                        frequency_penalty=0,
                        presence_penalty=0  
                    )
        response_message = response['choices'][0]['message']
        smoothed_text += response_message['content'] + '\n'
        text_part = ''
    elif split.startswith('\\section') or split.startswith('\\subsection'):
        current_section = split.replace('\\section', '').replace('\\subsection', '').replace('{', '').replace('}', '')
        text_part += split
    else:
        text_part += split
print('Writing output')
with open('smoothed_output', 'w') as f:
    f.write(smoothed_text)