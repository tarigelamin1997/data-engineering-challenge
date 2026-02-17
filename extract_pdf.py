
import pypdf
import sys

def extract_text(pdf_path):
    try:
        reader = pypdf.PdfReader(pdf_path)
        text = ""
        for i, page in enumerate(reader.pages):
            try:
                text += f"--- Page {i+1} ---\n"
                text += page.extract_text() + "\n"
            except Exception as e:
                text += f"[Error extraction page {i+1}: {e}]\n"
        return text
    except Exception as e:
        return str(e)

if __name__ == "__main__":
    pdf_path = "Data-engineering-role-challenge-due-march-1st.pdf"
    try:
        text = extract_text(pdf_path)
        with open("extracted_text_utf8.txt", "w", encoding="utf-8") as f:
            f.write(text)
        print("Done")
    except Exception as e:
        print(f"Critical error: {e}")
