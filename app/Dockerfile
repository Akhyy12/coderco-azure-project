FROM python
WORKDIR /app
COPY . .
RUN pip install flask -r requirements.txt
EXPOSE 3000
CMD ["gunicorn", "--bind", "0.0.0.0:3000", "--workers", "1", "app:app"]
