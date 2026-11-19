FROM python
WORKDIR /app
COPY . .
RUN pip install flask -r requirements.txt
EXPOSE 3000
CMD ["python", "app.py"]
