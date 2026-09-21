import os
import re

def remove_stray_logs(directory):
    # Regex to match the start of any print, debugPrint, NSLog, or AppLogger.multipeer call
    pattern = re.compile(r'(?:print|debugPrint|NSLog|AppLogger\.multipeer\.(?:info|debug|warning|error|fault|trace|critical))\s*\(')
    
    banned_keywords = [
        "TEST PASSED", "TEST FAILED", "DIRECT_CONVERSATION_ID", 
        "CHANNEL_CONVERSATION_ID", "MESSAGE_PERSISTED", "DIAG_HEARTBEAT", 
        "CHANNEL_PRESENCE", "MESH_QUEUE", "[PhysicalTest]", "[LoopbackTest]",
        "[LoopbackTransport]", "[PERSISTENCE]", "[Persistence]", "[AppLifecycle]",
        "[SubscriptionManager]", "[FeatureAccessManager]", "[Onboarding]", 
        "[BackgroundTasks]", "[Auth]", "[RevenueCat]", "[PersistenceTest]", 
        "[MESSAGE_DELETED]"
    ]
    
    modified_files = 0
    
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith('.swift'):
                filepath = os.path.join(root, file)
                
                with open(filepath, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                original_content = content
                
                # We need to iteratively find matches
                search_idx = 0
                while True:
                    match = pattern.search(content, search_idx)
                    if not match:
                        break
                    
                    start_idx = match.start()
                    paren_start_idx = match.end() - 1 # The '('
                    matched_func = match.group(0).strip()[:-1].strip() # e.g. 'print' or 'AppLogger.multipeer.info'
                    
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
                            
                        if content[end_idx:end_idx+3] == '"""':
                            if not in_string:
                                in_multiline_string = not in_multiline_string
                                end_idx += 3
                                continue
                            elif in_multiline_string:
                                in_multiline_string = False
                                end_idx += 3
                                continue
                        
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
                        
                        full_call = content[start_idx:end_idx]
                        
                        should_remove = False
                        if matched_func in ["print", "debugPrint", "NSLog"]:
                            should_remove = True
                        else:
                            for kw in banned_keywords:
                                if kw in full_call:
                                    should_remove = True
                                    break
                        
                        if should_remove:
                            line_start = start_idx
                            while line_start > 0 and content[line_start - 1] in [' ', '\t']:
                                line_start -= 1
                                
                            if line_start > 0 and content[line_start - 1] == '\n':
                                rest_of_line = end_idx
                                while rest_of_line < len(content) and content[rest_of_line] in [' ', '\t']:
                                    rest_of_line += 1
                                if rest_of_line < len(content) and content[rest_of_line] == '\n':
                                    end_idx = rest_of_line + 1
                                    start_idx = line_start
                                else:
                                    start_idx = line_start
                            else:
                                start_idx = line_start
                                
                            content = content[:start_idx] + content[end_idx:]
                            search_idx = start_idx
                        else:
                            search_idx = end_idx
                    else:
                        break
                        
                if content != original_content:
                    with open(filepath, 'w', encoding='utf-8') as f:
                        f.write(content)
                    modified_files += 1
                    print(f"Removed logs in {filepath}")
                    
    print(f"Total files modified: {modified_files}")

if __name__ == "__main__":
    remove_stray_logs("/Users/adityarai/Desktop/Pingly/Relyvo")
