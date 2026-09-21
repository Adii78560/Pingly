import os
import re

def remove_target_logs(directory):
    target_loggers = ['general', 'ble', 'audio', 'location', 'emergency', 'notifications']
    
    # Regex to match the start of a target log call
    # e.g., AppLogger.audio.info(
    pattern = re.compile(r'AppLogger\.(?:' + '|'.join(target_loggers) + r')\.(?:info|debug|warning|error|fault|trace|critical)\s*\(')
    
    modified_files = 0
    
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith('.swift'):
                filepath = os.path.join(root, file)
                
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                original_content = content
                
                # We need to iteratively find matches and remove them by matching parentheses
                while True:
                    match = pattern.search(content)
                    if not match:
                        break
                    
                    start_idx = match.start()
                    paren_start_idx = match.end() - 1 # The '('
                    
                    # Track parentheses to find the end of the call
                    paren_count = 0
                    in_string = False
                    in_multiline_string = False
                    escape_next = False
                    end_idx = paren_start_idx
                    
                    while end_idx < len(content):
                        char = content[end_idx]
                        
                        if escape_next:
                            escape_next = False
                            end_idx += 1
                            continue
                            
                        if char == '\\':
                            escape_next = True
                            end_idx += 1
                            continue
                            
                        # Handle multiline strings
                        if content[end_idx:end_idx+3] == '"""':
                            if not in_string:
                                in_multiline_string = not in_multiline_string
                                end_idx += 3
                                continue
                            elif in_multiline_string:
                                in_multiline_string = False
                                end_idx += 3
                                continue
                        
                        # Handle single-line strings
                        if char == '"' and not in_multiline_string:
                            in_string = not in_string
                            
                        if not in_string and not in_multiline_string:
                            if char == '(':
                                paren_count += 1
                            elif char == ')':
                                paren_count -= 1
                                if paren_count == 0:
                                    break
                                    
                        end_idx += 1
                    
                    if end_idx < len(content):
                        end_idx += 1 # Include the closing parenthesis
                        
                        # Remove leading whitespace on the line if it's just spaces/tabs before the log
                        line_start = start_idx
                        while line_start > 0 and content[line_start - 1] in [' ', '\t']:
                            line_start -= 1
                            
                        # If the line is now empty (only newline before and after), remove the line entirely
                        if line_start > 0 and content[line_start - 1] == '\n':
                            # Check if the rest of the line is just whitespace
                            rest_of_line = end_idx
                            while rest_of_line < len(content) and content[rest_of_line] in [' ', '\t']:
                                rest_of_line += 1
                            if rest_of_line < len(content) and content[rest_of_line] == '\n':
                                end_idx = rest_of_line + 1 # Include the trailing newline
                                start_idx = line_start
                            else:
                                start_idx = line_start
                        else:
                            start_idx = line_start
                            
                        content = content[:start_idx] + content[end_idx:]
                    else:
                        # Malformed or unbalanced, just break to avoid infinite loop
                        break
                        
                if content != original_content:
                    with open(filepath, 'w', encoding='utf-8') as f:
                        f.write(content)
                    modified_files += 1
                    print(f"Removed logs in {filepath}")
                    
    print(f"Total files modified: {modified_files}")

if __name__ == "__main__":
    remove_target_logs("/Users/adityarai/Desktop/Pingly/Relyvo")
