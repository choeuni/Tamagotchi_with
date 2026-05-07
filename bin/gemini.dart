import 'dart:io';
import 'package:google_generative_ai/google_generative_ai.dart';

void main(List<String> arguments) async {
  // 1. API 키 확인 (환경변수 'GEMINI_API_KEY' 사용)
  final apiKey = Platform.environment['GEMINI_API_KEY'];
  
  if (apiKey == null || apiKey.isEmpty) {
    print('--------------------------------------------------');
    print('에러: GEMINI_API_KEY 환경 변수가 설정되지 않았습니다.');
    print('설정 방법:');
    print('Windows (PowerShell): \$env:GEMINI_API_KEY="내_API_키"');
    print('Mac/Linux: export GEMINI_API_KEY="내_API_키"');
    print('--------------------------------------------------');
    return;
  }

  if (arguments.isEmpty) {
    print('사용법: dart bin/gemini.dart "질문할 내용"');
    return;
  }

  // 2. 모델 설정
  final model = GenerativeModel(
    model: 'gemini-1.5-flash',
    apiKey: apiKey,
  );

  final prompt = arguments.join(' ');
  final content = [Content.text(prompt)];

  try {
    print('🚀 Gemini가 답변을 생성 중입니다: "$prompt"');
    final response = await model.generateContent(content);
    
    print('\n✨ [Gemini 답변] ✨');
    print('--------------------------------------------------');
    print(response.text);
    print('--------------------------------------------------');
  } catch (e) {
    print('❌ 에러 발생: \$e');
  }
}
